import Foundation
import OSLog
import SwiftData
import UserNotifications

let agentLog = Logger(subsystem: "com.ideahelix.linkedmgr", category: "agent")

/// Publishes due posts and their first comments. Runs only inside the background agent,
/// so exactly one process ever publishes — the app just edits the database and kicks it.
///
/// LinkedIn has no scheduled publishing for members, hence the agent. A post whose time
/// passed while the Mac slept is still published on wake within the grace window;
/// later than that it's marked Missed so a stale "Good morning" post doesn't go out at 6 pm.
/// Network failures (e.g. Wi-Fi not back yet after wake) are retried on the next tick.
/// Videos are uploaded up to two hours ahead, since LinkedIn must process them before
/// they can be posted; a post whose video is still processing waits, within the grace window.
@MainActor
final class PublishEngine {
    static let tickInterval: TimeInterval = 30
    static let videoLeadTime: TimeInterval = 2 * 3600

    /// Hours after the slot during which a late post is still published.
    static var graceHours: Int {
        get { UserDefaults.standard.object(forKey: "graceHours") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "graceHours") }
    }

    private let container: ModelContainer
    private var busy = false
    private var activity: NSObjectProtocol?
    /// Last early-upload attempt per post, so a failing 500 MB upload isn't retried every tick.
    private var videoAttempts: [UUID: Date] = [:]

    private struct VideoNotReady: Error {}

    init(container: ModelContainer) {
        self.container = container
    }

    func recoverInterrupted() {
        // A post interrupted mid-publish goes back to the queue; one with a URN went out.
        let context = ModelContext(container)
        for post in (try? context.fetch(FetchDescriptor<Post>())) ?? [] where post.status == .publishing {
            post.status = post.postURN == nil ? .scheduled : .published
        }
        save(context)
    }

    func tick() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        // A fresh context each tick, so edits the app made since are always seen.
        let context = ModelContext(container)
        let posts = (try? context.fetch(FetchDescriptor<Post>())) ?? []
        let now = Date()
        updateSleepAssertion(posts: posts, now: now)

        for post in posts where post.status == .scheduled && post.videoFileName != nil && post.videoURN == nil {
            guard let due = post.scheduledAt, due > now, due.timeIntervalSince(now) < Self.videoLeadTime,
                  videoAttempts[post.id].map({ now.timeIntervalSince($0) > 600 }) ?? true else { continue }
            videoAttempts[post.id] = now
            await uploadVideoEarly(post, context: context)
        }

        for post in posts where post.status == .scheduled {
            guard let due = post.scheduledAt, due <= now else { continue }
            if now.timeIntervalSince(due) > TimeInterval(Self.graceHours * 3600) {
                post.status = .missed
                post.lastError = (post.lastError.map { $0 + " " } ?? "")
                    + "Not published by \(due.addingTimeInterval(TimeInterval(Self.graceHours * 3600)).formatted(date: .abbreviated, time: .shortened)) (Mac asleep, offline, or agent off)."
                save(context)
                notify("Post missed", "“\(post.displayTitle)” wasn't published. Reschedule it in LinkedMgr.")
                continue
            }
            await publish(post, context: context)
        }

        for post in posts where post.status == .published && post.commentStatus == .pending {
            guard let publishedAt = post.publishedAt,
                  now >= publishedAt.addingTimeInterval(TimeInterval(post.commentDelayMinutes * 60)) else { continue }
            await postComment(post, context: context)
        }
    }

    private func publish(_ post: Post, context: ModelContext) async {
        guard let client = LinkedInAccount.currentClient() else {
            post.status = .failed
            post.lastError = "Not connected to LinkedIn (or the sign-in expired). Reconnect in Settings, then reschedule."
            save(context)
            notify("Couldn't publish", post.lastError!)
            return
        }
        agentLog.info("Publishing \(post.displayTitle, privacy: .public)")
        post.status = .publishing
        post.lastError = nil
        save(context)
        do {
            var video: (urn: String, title: String)?
            var uploaded: [(urn: String, altText: String)] = []
            if let videoURL = post.videoURL {
                video = (try await readyVideo(post, file: videoURL, client: client, context: context),
                         post.videoTitle.isEmpty ? post.title : post.videoTitle)
            } else {
                for image in post.orderedImages {
                    uploaded.append((try await client.uploadImage(at: image.url), image.altText))
                }
            }
            let urn = try await client.createPost(commentary: LittleText.commentary(post.text), images: uploaded, video: video)
            post.postURN = urn
            post.publishedAt = Date()
            post.status = .published
            post.commentStatus = post.hasComment ? .pending : .none
            save(context)
            agentLog.info("Published \(urn, privacy: .public)")
            notify("Published to LinkedIn", post.displayTitle, url: post.postURL)
            let unresolved = LittleText.unresolvedMentions(post.text)
            if !unresolved.isEmpty {
                notify("Tag by hand", "Edit the post on LinkedIn to tag: \(unresolved.joined(separator: ", "))", url: post.postURL)
            }
            if post.commentStatus == .pending, post.commentDelayMinutes == 0 {
                await postComment(post, context: context)
            }
        } catch is VideoNotReady {
            post.status = .scheduled
            post.lastError = "Waiting for LinkedIn to finish processing the video."
            save(context)
        } catch {
            agentLog.error("Publish failed: \(error.localizedDescription, privacy: .public)")
            if Self.isTransient(error) {
                // Stay scheduled; the next tick retries until the grace window runs out.
                post.status = .scheduled
                post.lastError = "Retrying: \(error.localizedDescription)"
            } else {
                post.status = .failed
                post.lastError = error.localizedDescription
                notify("Couldn't publish “\(post.displayTitle)”", error.localizedDescription)
            }
            save(context)
        }
    }

    /// Uploads the video if needed and returns its URN once LinkedIn has processed it.
    private func readyVideo(_ post: Post, file: URL, client: LinkedInClient, context: ModelContext) async throws -> String {
        let urn: String
        if let existing = post.videoURN {
            urn = existing
        } else {
            agentLog.info("Uploading video for \(post.displayTitle, privacy: .public)")
            urn = try await client.uploadVideo(at: file)
            post.videoURN = urn
            save(context)
        }
        let state = try await client.videoStatus(urn)
        switch state.status {
        case "AVAILABLE":
            return urn
        case "PROCESSING_FAILED":
            post.videoURN = nil
            throw LinkedInError.message("LinkedIn couldn't process the video (\(state.failureReason ?? "no reason given")). Re-export it as an MP4 and try again.")
        default:
            agentLog.info("Video \(urn, privacy: .public) is \(state.status, privacy: .public); waiting")
            throw VideoNotReady()
        }
    }

    private func uploadVideoEarly(_ post: Post, context: ModelContext) async {
        guard let client = LinkedInAccount.currentClient(), let file = post.videoURL else { return }
        do {
            agentLog.info("Uploading video ahead for \(post.displayTitle, privacy: .public)")
            post.videoURN = try await client.uploadVideo(at: file)
            save(context)
        } catch {
            // Not fatal: publishing uploads it again and reports any error then.
            agentLog.error("Early video upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postComment(_ post: Post, context: ModelContext) async {
        guard let client = LinkedInAccount.currentClient(), let urn = post.postURN else { return }
        let message = LittleText.commentMessage(post.commentText)
        do {
            post.commentURN = try await client.createComment(on: urn, text: message.text, attributes: message.attributes)
            post.commentStatus = .posted
        } catch {
            agentLog.error("Comment failed: \(error.localizedDescription, privacy: .public)")
            if !Self.isTransient(error) {
                post.commentStatus = .failed
                post.lastError = "Comment failed: \(error.localizedDescription)"
                notify("Couldn't add the comment", error.localizedDescription, url: post.postURL)
            }
        }
        save(context)
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case LinkedInError.http(let status, _) = error { return status == 429 || status >= 500 }
        return false
    }

    private func save(_ context: ModelContext) {
        do { try context.save() } catch { agentLog.error("Save failed: \(error.localizedDescription, privacy: .public)") }
        Signal.changed.post()
    }

    /// Keeps the Mac from idle-sleeping in the 20 minutes before a post is due.
    /// (Closing the lid still sleeps it; see Settings → Schedule for waking the Mac.)
    private func updateSleepAssertion(posts: [Post], now: Date) {
        let dueSoon = posts.contains { post in
            post.status == .scheduled && post.scheduledAt.map { $0.timeIntervalSince(now) < 20 * 60 } == true
        } || posts.contains { $0.commentStatus == .pending && $0.status == .published }
        if dueSoon, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiatedAllowingIdleSystemSleep],
                reason: "A LinkedIn post is about to be published")
        } else if !dueSoon, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func notify(_ title: String, _ body: String, url: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url { content.userInfo = ["url": url.absoluteString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
