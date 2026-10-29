import SwiftData
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case plan, drafts, attention, published, contacts
    var id: Self { self }

    var label: String {
        switch self {
        case .plan: "Content Plan"
        case .drafts: "Drafts"
        case .attention: "Needs Attention"
        case .published: "Published"
        case .contacts: "People & Companies"
        }
    }

    var symbol: String {
        switch self {
        case .plan: "calendar"
        case .drafts: "square.and.pencil"
        case .attention: "exclamationmark.triangle"
        case .published: "checkmark.circle"
        case .contacts: "person.2"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Post.createdAt, order: .reverse) private var posts: [Post]
    @State private var sidebar: SidebarItem? = .plan
    @State private var selectedPost: PersistentIdentifier?
    @State private var selectedContact: PersistentIdentifier?
    private var account = LinkedInAccount.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { AccountBadge().padding(10) }
        } content: {
            switch sidebar ?? .plan {
            case .plan:
                PlanView(selection: $selectedPost, newPost: newPost)
            case .drafts:
                PostList(title: "Drafts", posts: posts.filter { $0.status == .draft }, selection: $selectedPost,
                         empty: "No drafts. Press ⌘N to write one.")
            case .attention:
                PostList(title: "Needs Attention", posts: posts.filter { [.failed, .missed].contains($0.status) },
                         selection: $selectedPost, empty: "Nothing needs attention.")
            case .published:
                PostList(title: "Published",
                         posts: posts.filter { $0.status == .published }
                             .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) },
                         selection: $selectedPost, empty: "Nothing published yet.")
            case .contacts:
                ContactsList(selection: $selectedContact)
            }
        } detail: {
            if sidebar == .contacts {
                if let id = selectedContact, let contact = context.model(for: id) as? Contact {
                    ContactEditor(contact: contact).id(id)
                } else {
                    ContentUnavailableView("Select a person or company", systemImage: "person.2",
                                           description: Text("Tags link only when the name matches their LinkedIn name exactly."))
                }
            } else if let id = selectedPost, let post = context.model(for: id) as? Post, !post.isDeleted {
                PostEditor(post: post).id(id)
            } else {
                ContentUnavailableView {
                    Label("No post selected", systemImage: "text.below.photo")
                } actions: {
                    Button("New Post", action: { newPost(nil) })
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { newPost(nil) } label: { Label("New Post", systemImage: "plus") }
                    .help("New post (⌘N)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newPost)) { _ in newPost(nil) }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .drafts: posts.filter { $0.status == .draft }.count
        case .attention: posts.filter { [.failed, .missed].contains($0.status) }.count
        default: 0
        }
    }

    /// Creates a post, optionally already scheduled into a slot.
    private func newPost(_ slot: Date?) {
        let post = Post()
        if let slot {
            post.scheduledAt = slot
            post.status = .scheduled
        }
        context.insert(post)
        try? context.save()
        if slot == nil, sidebar != .plan { sidebar = .drafts }
        if sidebar == .contacts { sidebar = .drafts }
        selectedPost = post.persistentModelID
    }
}

struct AccountBadge: View {
    private var account = LinkedInAccount.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(account.isConnected ? (account.expiresSoon ? .orange : .green) : .red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.isConnected ? (account.memberName ?? "Connected") : "Not connected")
                    .font(.caption)
                if account.isConnected, account.expiresSoon, let exp = account.tokenExpiresAt {
                    Text("Reconnect by \(exp.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
        }
    }
}

struct PostList: View {
    let title: String
    let posts: [Post]
    @Binding var selection: PersistentIdentifier?
    let empty: String
    @Environment(\.modelContext) private var context

    var body: some View {
        List(selection: $selection) {
            ForEach(posts) { post in
                PostRow(post: post).tag(post.persistentModelID)
                    .contextMenu { PostContextMenu(post: post) }
            }
        }
        .overlay { if posts.isEmpty { ContentUnavailableView(empty, systemImage: "tray") } }
        .navigationTitle(title)
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
    }
}

struct PostRow: View {
    let post: Post

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(image: post.orderedImages.first, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(post.displayTitle).lineLimit(1).font(.headline)
                HStack(spacing: 6) {
                    Label(post.status.label, systemImage: post.status.symbol)
                        .foregroundStyle(statusColor)
                    if let date = post.publishedAt ?? post.scheduledAt {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                HStack(spacing: 8) {
                    if post.images.count > 0 { Label("\(post.images.count)", systemImage: "photo") }
                    if post.hasComment { Label("Comment", systemImage: "link") }
                    if !LittleText.unresolvedMentions(post.text).isEmpty { Label("Manual tags", systemImage: "at") }
                }
                .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch post.status {
        case .published: .green
        case .failed, .missed: .orange
        case .scheduled, .publishing: .accentColor
        case .draft: .secondary
        }
    }
}

struct PostContextMenu: View {
    let post: Post
    @Environment(\.modelContext) private var context

    var body: some View {
        if post.isEditable {
            Button("Schedule in Next Free Slot") { Scheduling.scheduleNextFree(post, context: context) }
            if post.status != .draft {
                Button("Move to Drafts") { post.status = .draft; post.scheduledAt = nil }
            }
        }
        if let url = post.postURL {
            Button("Open on LinkedIn") { NSWorkspace.shared.open(url) }
        }
        Button("Duplicate") { Scheduling.duplicate(post, context: context) }
        Divider()
        Button("Delete", role: .destructive) { Scheduling.delete(post, context: context) }
    }
}

struct Thumbnail: View {
    let image: PostImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image, let ns = NSImage(contentsOf: image.url) {
                Image(nsImage: ns).resizable().scaledToFill()
            } else {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Post operations shared by the lists, plan and editor.
@MainActor
enum Scheduling {
    static func takenSlots(context: ModelContext, excluding post: Post? = nil) -> [Date] {
        let posts = (try? context.fetch(FetchDescriptor<Post>())) ?? []
        return posts.filter { $0 !== post && [.scheduled, .publishing, .published].contains($0.status) }
            .compactMap { $0.scheduledAt ?? $0.publishedAt }
    }

    static func scheduleNextFree(_ post: Post, context: ModelContext) {
        let taken = takenSlots(context: context, excluding: post)
        guard let slot = PostingSchedule.load().nextFreeSlot(after: Date(), taken: taken) else { return }
        post.scheduledAt = slot
        post.status = .scheduled
        post.lastError = nil
        try? context.save()
    }

    static func duplicate(_ post: Post, context: ModelContext) {
        let copy = Post(title: post.title.isEmpty ? "" : post.title + " (copy)", text: post.text)
        copy.commentText = post.commentText
        copy.commentDelayMinutes = post.commentDelayMinutes
        context.insert(copy)
        for image in post.orderedImages {
            if let data = try? Data(contentsOf: image.url), let name = try? ImageStore.save(data) {
                let newImage = PostImage(fileName: name, order: image.order)
                newImage.altText = image.altText
                copy.images.append(newImage)
            }
        }
        try? context.save()
    }

    static func delete(_ post: Post, context: ModelContext) {
        post.images.forEach { ImageStore.delete($0.fileName) }
        context.delete(post)
        try? context.save()
    }
}
