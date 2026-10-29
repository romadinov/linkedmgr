import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import LinkedMgr

struct LittleTextTests {
    @Test func escapesReservedCharactersButKeepsHashtags() {
        #expect(LittleText.commentary("Hi (all) * see #swift and C# _x_") == ##"Hi \(all\) \* see #swift and C\# \_x\_"##)
    }

    @Test func resolvedMentionsPassThrough() {
        let text = "Thanks @[Acme Corp](urn:li:organization:42) and @[Jane](urn:li:person:abc)!"
        #expect(LittleText.commentary(text) == "Thanks @[Acme Corp](urn:li:organization:42) and @[Jane](urn:li:person:abc)!")
    }

    @Test func unresolvedMentionsBecomePlainText() {
        let text = "Great talk by @[Jane Doe]() today"
        #expect(LittleText.commentary(text) == "Great talk by Jane Doe today")
        #expect(LittleText.unresolvedMentions(text) == ["Jane Doe"])
    }

    @Test func commentAttributesUseUTF16Offsets() {
        let message = LittleText.commentMessage("🚀 Link: https://x.io via @[Acme](urn:li:organization:1)")
        #expect(message.text == "🚀 Link: https://x.io via Acme")
        #expect(message.attributes == [.init(start: 26, length: 4, urn: "urn:li:organization:1")])
    }
}

struct PostingScheduleTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func skipsWeekendsAndPastTimes() {
        // Friday 2026-10-30 at noon: Friday's 10:00 slot has passed, so next is Monday.
        let slots = PostingSchedule.default.upcomingSlots(after: date(2026, 10, 30, 12), limit: 2, calendar: calendar)
        #expect(slots == [date(2026, 11, 2, 10), date(2026, 11, 3, 10, 30)])
    }

    @Test func nextFreeSlotSkipsTakenDaysAndDaysOff() {
        var schedule = PostingSchedule.default
        schedule.skipDays = [date(2026, 11, 3)]
        let slot = schedule.nextFreeSlot(after: date(2026, 11, 1), taken: [date(2026, 11, 2, 15)], calendar: calendar)
        #expect(slot == date(2026, 11, 4, 11))
    }
}

@MainActor
struct PublishEngineTests {
    let container = try! ModelContainer(for: Post.self, PostImage.self, Contact.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))

    func insert(_ configure: (Post) -> Void) -> Post {
        let post = Post(text: "Hello")
        configure(post)
        container.mainContext.insert(post)
        try! container.mainContext.save()
        return post
    }

    func fetch() -> [Post] {
        try! ModelContext(container).fetch(FetchDescriptor<Post>())
    }

    @Test func postPastGraceWindowIsMarkedMissed() async {
        _ = insert { $0.status = .scheduled; $0.scheduledAt = Date().addingTimeInterval(-24 * 3600) }
        await PublishEngine(container: container).tick()
        #expect(fetch().first?.status == .missed)
    }

    @Test func futurePostIsLeftAlone() async {
        _ = insert { $0.status = .scheduled; $0.scheduledAt = Date().addingTimeInterval(3600) }
        await PublishEngine(container: container).tick()
        #expect(fetch().first?.status == .scheduled)
    }

    @Test func interruptedPublishIsRequeued() {
        _ = insert { $0.status = .publishing }
        _ = insert { $0.status = .publishing; $0.postURN = "urn:li:share:1" }
        PublishEngine(container: container).recoverInterrupted()
        #expect(Set(fetch().map(\.status)) == [.scheduled, .published])
    }

    @Test func networkAndServerErrorsAreRetried() {
        #expect(PublishEngine.isTransient(URLError(.notConnectedToInternet)))
        #expect(PublishEngine.isTransient(LinkedInError.http(status: 503, body: "")))
        #expect(!PublishEngine.isTransient(LinkedInError.http(status: 403, body: "")))
    }
}

struct PostBodyTests {
    @Test func videoGoesInMediaWithTitle() {
        let body = LinkedInClient.postBody(author: "urn:li:person:1", commentary: "Hi", images: [],
                                           video: ("urn:li:video:V", "Demo"))
        let media = (body["content"] as? [String: Any])?["media"] as? [String: String]
        #expect(media == ["id": "urn:li:video:V", "title": "Demo"])
    }

    @Test func severalImagesGoInMultiImage() {
        let body = LinkedInClient.postBody(author: "urn:li:person:1", commentary: "Hi",
                                           images: [("urn:li:image:A", ""), ("urn:li:image:B", "alt")], video: nil)
        let images = ((body["content"] as? [String: Any])?["multiImage"] as? [String: Any])?["images"] as? [[String: String]]
        #expect(images == [["id": "urn:li:image:A"], ["id": "urn:li:image:B", "altText": "alt"]])
    }
}

struct VideoStoreTests {
    /// Writes a solid-colour H.264 QuickTime movie, like a clip exported from Photos.
    static func makeMovie(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func movIsConvertedToMP4() async throws {
        let source = try await Self.makeMovie(seconds: 4)
        defer { try? FileManager.default.removeItem(at: source) }
        let name = try await VideoStore.save(contentsOf: source)
        defer { VideoStore.delete(name) }
        #expect(name.hasSuffix(".mp4"))
        let duration = try #require(await VideoStore.duration(name))
        #expect(abs(duration - 4) < 0.5)
        #expect(await VideoStore.thumbnail(name, maxSize: 44) != nil)
    }

    @Test func tooShortIsRejected() async throws {
        let source = try await Self.makeMovie(seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: VideoStore.VideoError.self) { _ = try await VideoStore.save(contentsOf: source) }
    }
}
