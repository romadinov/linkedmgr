import AppKit
import Foundation
import Observation
import SwiftData
import UserNotifications

/// Publishes scheduled posts when they fall due and posts their first comments.
///
/// LinkedIn's API has no scheduled publishing for members, so the app itself must be
/// running (it lives in the menu bar and can launch at login). A post whose time passed
/// while the Mac slept is still published on wake if it's within the grace window;
/// otherwise it's marked Missed so a stale "Good morning" post doesn't go out at 6 pm.
@MainActor @Observable
final class Publisher {
    static let shared = Publisher()

    var container: ModelContainer?
    private(set) var busy = false
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    /// Hours after the slot during which a missed post is still published.
    var graceHours: Int {
        get { UserDefaults.standard.object(forKey: "graceHours") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "graceHours") }
    }

    func start(container: ModelContainer) {
        guard timer == nil else { return }
        self.container = container
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // A post interrupted mid-publish (app quit, crash) goes back to the queue.
        // Posts that already have a URN went out; only their comment may be outstanding.
        let context = container.mainContext
        for post in (try? context.fetch(FetchDescriptor<Post>())) ?? [] where post.status == .publishing {
            post.status = post.postURN == nil ? .scheduled : .published
        }
        try? context.save()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await Publisher.shared.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // Give Wi-Fi a moment to come back after wake.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                await Publisher.shared.tick()
            }
        }
        Task { await tick() }
    }

    func tick() async {
        guard !busy, let context = container?.mainContext else { return }
        busy = true
        defer { busy = false }

        let posts = (try? context.fetch(FetchDescriptor<Post>())) ?? []
        let now = Date()
        updateSleepAssertion(posts: posts, now: now)

        for post in posts where post.status == .scheduled {
            guard let due = post.scheduledAt, due <= now else { continue }
            if now.timeIntervalSince(due) > TimeInterval(graceHours * 3600) {
                post.status = .missed
                post.lastError = "The Mac was asleep or LinkedMgr wasn't running at \(due.formatted(date: .abbreviated, time: .shortened))."
                notify("Post missed", "“\(post.displayTitle)” wasn't published. Reschedule it in LinkedMgr.")
                continue
            }
            await publish(post)
        }

        for post in posts where post.status == .published && post.commentStatus == .pending {
            guard let publishedAt = post.publishedAt,
                  now >= publishedAt.addingTimeInterval(TimeInterval(post.commentDelayMinutes * 60)) else { continue }
            await postComment(post)
        }
        try? context.save()
    }

    /// Uploads images, creates the post, and queues the first comment.
    func publish(_ post: Post) async {
        guard let client = LinkedInAccount.shared.client else {
            post.status = .failed
            post.lastError = "Not connected to LinkedIn. Connect in Settings, then retry."
            notify("Couldn't publish", post.lastError!)
            return
        }
        let unresolved = LittleText.unresolvedMentions(post.text)
        post.status = .publishing
        post.lastError = nil
        try? container?.mainContext.save()
        do {
            var uploaded: [(urn: String, altText: String)] = []
            for image in post.orderedImages {
                uploaded.append((try await client.uploadImage(at: image.url), image.altText))
            }
            let urn = try await client.createPost(commentary: LittleText.commentary(post.text), images: uploaded)
            post.postURN = urn
            post.publishedAt = Date()
            post.status = .published
            post.commentStatus = post.hasComment ? .pending : .none
            notify("Published to LinkedIn", post.displayTitle, url: post.postURL)
            if !unresolved.isEmpty {
                notify("Tag by hand", "Edit the post on LinkedIn to tag: \(unresolved.joined(separator: ", "))", url: post.postURL)
            }
        } catch {
            post.status = .failed
            post.lastError = error.localizedDescription
            notify("Couldn't publish “\(post.displayTitle)”", error.localizedDescription)
        }
        try? container?.mainContext.save()
        if post.commentStatus == .pending, post.commentDelayMinutes == 0 {
            await postComment(post)
        }
    }

    func postComment(_ post: Post) async {
        guard let client = LinkedInAccount.shared.client, let urn = post.postURN else { return }
        let message = LittleText.commentMessage(post.commentText)
        do {
            post.commentURN = try await client.createComment(on: urn, text: message.text, attributes: message.attributes)
            post.commentStatus = .posted
        } catch {
            post.commentStatus = .failed
            post.lastError = "Comment failed: \(error.localizedDescription)"
            notify("Couldn't add the comment", error.localizedDescription, url: post.postURL)
        }
        try? container?.mainContext.save()
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
