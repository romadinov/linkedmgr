import Foundation
import SwiftData

enum PostStatus: String, CaseIterable {
    case draft, scheduled, publishing, published, failed, missed

    var label: String {
        switch self {
        case .draft: "Draft"
        case .scheduled: "Scheduled"
        case .publishing: "Publishing…"
        case .published: "Published"
        case .failed: "Failed"
        case .missed: "Missed"
        }
    }

    var symbol: String {
        switch self {
        case .draft: "square.and.pencil"
        case .scheduled: "clock"
        case .publishing: "arrow.up.circle"
        case .published: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .missed: "moon.zzz.fill"
        }
    }
}

enum CommentStatus: String {
    case none, pending, posted, failed
}

@Model
final class Post {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Internal working title, never published.
    var title: String = ""
    var text: String = ""
    var statusRaw: String = PostStatus.draft.rawValue
    var scheduledAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \PostImage.post)
    var images: [PostImage] = []

    /// A post has either pictures or one video (LinkedIn allows only one kind of media).
    /// File name inside `VideoStore.directory`.
    var videoFileName: String?
    var videoTitle: String = ""
    /// `urn:li:video:…` once uploaded. Uploaded ahead of the slot so LinkedIn has time
    /// to process it; cleared whenever the video is replaced.
    var videoURN: String?

    /// Optional first comment (typically the link), posted after the post goes live.
    var commentText: String = ""
    var commentDelayMinutes: Int = 1
    var commentStatusRaw: String = CommentStatus.none.rawValue
    var commentURN: String?

    var postURN: String?
    var publishedAt: Date?
    var lastError: String?

    init(title: String = "", text: String = "") {
        self.title = title
        self.text = text
    }

    var status: PostStatus {
        get { PostStatus(rawValue: statusRaw) ?? .draft }
        set { statusRaw = newValue.rawValue }
    }

    var commentStatus: CommentStatus {
        get { CommentStatus(rawValue: commentStatusRaw) ?? .none }
        set { commentStatusRaw = newValue.rawValue }
    }

    var orderedImages: [PostImage] {
        images.sorted { $0.order < $1.order }
    }

    var videoURL: URL? {
        videoFileName.map { VideoStore.directory.appendingPathComponent($0) }
    }

    var hasComment: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = LittleText.displayText(text).split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled post" : String(firstLine.prefix(80))
    }

    var postURL: URL? {
        postURN.flatMap { URL(string: "https://www.linkedin.com/feed/update/\($0)/") }
    }

    /// Editable unless it's on its way out or already out.
    var isEditable: Bool {
        status != .publishing && status != .published
    }
}

@Model
final class PostImage {
    var id: UUID = UUID()
    /// File name inside `ImageStore.directory`.
    var fileName: String = ""
    var order: Int = 0
    var altText: String = ""
    var post: Post?

    init(fileName: String, order: Int) {
        self.fileName = fileName
        self.order = order
    }

    var url: URL { ImageStore.directory.appendingPathComponent(fileName) }
}

enum ContactKind: String, CaseIterable {
    case person, organization

    var label: String { self == .person ? "Person" : "Company" }
    var symbol: String { self == .person ? "person.crop.circle" : "building.2" }
}

/// Someone you tag. The name must match their LinkedIn name exactly for the tag to link.
@Model
final class Contact {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = ContactKind.person.rawValue
    /// `urn:li:person:…` or `urn:li:organization:…`. Empty means "tag by hand after publishing".
    var urn: String = ""
    var profileURL: String = ""
    var note: String = ""

    init(name: String, kind: ContactKind, urn: String = "") {
        self.name = name
        self.kindRaw = kind.rawValue
        self.urn = urn
    }

    var kind: ContactKind {
        get { ContactKind(rawValue: kindRaw) ?? .person }
        set { kindRaw = newValue.rawValue }
    }

    var mentionToken: String {
        LittleText.mentionToken(name: name, urn: urn.isEmpty ? nil : urn)
    }
}
