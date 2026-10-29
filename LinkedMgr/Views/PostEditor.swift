import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PostEditor: View {
    @Bindable var post: Post
    @Environment(\.modelContext) private var context
    @Query(sort: \Contact.name) private var contacts: [Contact]

    @State private var textSelection: TextSelection?
    @State private var commentSelection: TextSelection?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var confirmPublishNow = false
    @State private var editingAltText: PostImage?
    @State private var preparingVideo = false

    private static let maxLength = 3000
    private var locked: Bool { !post.isEditable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusBanner
                TextField("Working title (not published)", text: $post.title)
                    .textFieldStyle(.plain).font(.title2.weight(.semibold))

                section("Post") {
                    TextEditor(text: $post.text, selection: $textSelection)
                        .font(.body)
                        .frame(minHeight: 220)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    HStack {
                        MentionMenu(contacts: contacts) { insert($0, into: \.text, selection: $textSelection) }
                        Text("Tags look like @[Name](urn). Hashtags work as usual.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        let count = LittleText.displayText(post.text).count
                        Text("\(count) / \(Self.maxLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(count > Self.maxLength ? .red : .secondary)
                    }
                }

                section("Pictures or video") {
                    if let video = post.videoFileName { videoSection(video) } else { imagesSection }
                }

                section("First comment") {
                    TextEditor(text: $post.commentText, selection: $commentSelection)
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    HStack {
                        MentionMenu(contacts: contacts) { insert($0, into: \.commentText, selection: $commentSelection) }
                        Text("Optional — e.g. the link, so the post itself isn't link-throttled.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Stepper("Post \(post.commentDelayMinutes == 0 ? "immediately" : "\(post.commentDelayMinutes) min after")",
                                value: $post.commentDelayMinutes, in: 0...120)
                            .font(.caption)
                    }
                }

                section("Preview") { PostPreview(post: post) }
            }
            .padding(24)
            .disabled(locked)
        }
        .navigationTitle(post.displayTitle)
        .toolbar { scheduleToolbar }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let isVideo = { (url: URL) in UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true }
            if let video = urls.first(where: isVideo) {
                if urls.count > 1 { importError = "A LinkedIn post has either pictures or one video. Adding only the video." }
                addVideo(from: video)
            } else {
                addImages(urls.map { url in { try ImageStore.save(contentsOf: url) } })
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var loaders: [() throws -> String] = []
                for item in items {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if items.count > 1 { importError = "A LinkedIn post has either pictures or one video. Adding only the video." }
                        if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                            addVideo(from: movie.url, deleteAfter: true)
                        } else {
                            importError = "Couldn't load that video from Photos."
                        }
                        loaders = []
                        break
                    }
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        loaders.append { try ImageStore.save(data) }
                    }
                }
                addImages(loaders)
                photoItems = []
            }
        }
        // iPhone/iPad camera via Continuity Camera: File ▸ Import from iPhone or iPad.
        .importsItemProviders([.image]) { providers in
            loadProviders(providers)
            return true
        }
        .alert("Couldn't add that", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .confirmationDialog("Publish this post to LinkedIn now?", isPresented: $confirmPublishNow) {
            Button("Publish Now") {
                post.scheduledAt = Date()
                post.status = .scheduled
                post.lastError = nil
                StoreRefresher.shared.commitAndKick()
            }
        }
        .sheet(item: $editingAltText) { image in AltTextSheet(image: image) }
        .onChange(of: post.text) { try? context.save() }
    }

    // MARK: Sections

    @ViewBuilder private var statusBanner: some View {
        if let error = post.lastError, [.failed, .missed].contains(post.status) || post.commentStatus == .failed {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if post.status == .published {
            HStack {
                Label("Published \(post.publishedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if post.hasComment {
                    Text("· comment \(post.commentStatus == .posted ? "posted" : post.commentStatus.rawValue)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if post.commentStatus == .failed {
                    Button("Retry Comment") {
                        post.commentStatus = .pending
                        StoreRefresher.shared.commitAndKick()
                    }
                }
                if let url = post.postURL { Link("Open on LinkedIn", destination: url) }
            }
            let unresolved = LittleText.unresolvedMentions(post.text)
            if !unresolved.isEmpty {
                Label("Tag by hand on LinkedIn (Edit post): \(unresolved.joined(separator: ", "))", systemImage: "at")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(post.orderedImages.enumerated()), id: \.element.id) { index, image in
                        ImageTile(image: image, index: index, count: post.images.count,
                                  move: { moveImage(image, by: $0) },
                                  remove: { removeImage(image) },
                                  editAlt: { editingAltText = image })
                    }
                    if post.images.isEmpty {
                        Text("No pictures — text-only post. Drop images here, or pick one video.")
                            .foregroundStyle(.secondary).frame(height: 120)
                    }
                }
            }
            .dropDestination(for: Data.self) { items, _ in
                addImages(items.map { data in { try ImageStore.save(data) } })
                return true
            }
            HStack {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                    Label("Photos…", systemImage: "photo.on.rectangle")
                }
                Button { showFileImporter = true } label: { Label("Files…", systemImage: "folder") }
                Text("Camera: File ▸ Import from iPhone ▸ Take Photo")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if preparingVideo {
                    ProgressView().controlSize(.small)
                    Text("Preparing video…").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(post.images.count) / 20").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func videoSection(_ fileName: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VideoThumbnail(fileName: fileName, size: 160)
                .onTapGesture { post.videoURL.map { NSWorkspace.shared.open($0) } }
                .help("Play")
            VStack(alignment: .leading, spacing: 8) {
                TextField("Video title (optional, shown with the video)", text: $post.videoTitle)
                VideoFacts(fileName: fileName)
                HStack {
                    Button("Play") { post.videoURL.map { NSWorkspace.shared.open($0) } }
                    Button("Remove Video", role: .destructive) { removeVideo() }
                }
                Text("LinkedMgr uploads the video up to 2 hours before its slot so LinkedIn can process it in time. A post has either pictures or one video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder private var scheduleToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if post.isEditable {
                if post.status == .scheduled, post.scheduledAt != nil {
                    DatePicker("", selection: Binding(get: { post.scheduledAt ?? Date() },
                                                      set: { post.scheduledAt = $0 }),
                               in: Date()...)
                        .labelsHidden()
                    Button("Unschedule") { post.status = .draft; post.scheduledAt = nil }
                } else {
                    Button { Scheduling.scheduleNextFree(post, context: context) } label: {
                        Label("Schedule", systemImage: "calendar.badge.clock")
                    }
                    .help("Put in the next free slot of your content plan")
                }
                Button { confirmPublishNow = true } label: { Label("Publish Now", systemImage: "paperplane") }
                    .disabled(!canPublish)
            }
        }
    }

    private var canPublish: Bool {
        let length = LittleText.displayText(post.text).count
        return LinkedInAccount.shared.isConnected && !preparingVideo && length > 0 && length <= Self.maxLength
    }

    // MARK: Actions

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func insert(_ token: String, into keyPath: ReferenceWritableKeyPath<Post, String>, selection: Binding<TextSelection?>) {
        var text = post[keyPath: keyPath]
        if case .selection(let range)? = selection.wrappedValue?.indices,
           range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            text.replaceSubrange(range, with: token)
        } else {
            text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + token
        }
        post[keyPath: keyPath] = text
    }

    private func addImages(_ loaders: [() throws -> String]) {
        guard post.videoFileName == nil || loaders.isEmpty else {
            importError = "A LinkedIn post has either pictures or one video. Remove the video first."
            return
        }
        var order = (post.images.map(\.order).max() ?? -1) + 1
        for load in loaders where post.images.count < 20 {
            do {
                post.images.append(PostImage(fileName: try load(), order: order))
                order += 1
            } catch {
                importError = error.localizedDescription
            }
        }
        try? context.save()
    }

    /// Copies or converts the video (can take a while for long iPhone clips).
    private func addVideo(from url: URL, deleteAfter: Bool = false) {
        guard post.images.isEmpty else {
            importError = "A LinkedIn post has either pictures or one video. Remove the pictures first."
            if deleteAfter { try? FileManager.default.removeItem(at: url) }
            return
        }
        preparingVideo = true
        Task {
            defer {
                preparingVideo = false
                if deleteAfter { try? FileManager.default.removeItem(at: url) }
            }
            do {
                let name = try await VideoStore.save(contentsOf: url)
                if let old = post.videoFileName { VideoStore.delete(old) }
                post.videoFileName = name
                post.videoURN = nil
                try? context.save()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func removeVideo() {
        post.videoFileName.map(VideoStore.delete)
        post.videoFileName = nil
        post.videoURN = nil
        try? context.save()
    }

    private func loadProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else { return }
                Task { @MainActor in addImages([{ try ImageStore.save(data) }]) }
            }
        }
    }

    private func moveImage(_ image: PostImage, by offset: Int) {
        var ordered = post.orderedImages
        guard let i = ordered.firstIndex(where: { $0 === image }) else { return }
        let j = i + offset
        guard ordered.indices.contains(j) else { return }
        ordered.swapAt(i, j)
        for (n, img) in ordered.enumerated() { img.order = n }
        try? context.save()
    }

    private func removeImage(_ image: PostImage) {
        ImageStore.delete(image.fileName)
        post.images.removeAll { $0 === image }
        context.delete(image)
        try? context.save()
    }
}

private struct ImageTile: View {
    let image: PostImage
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void
    let editAlt: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Thumbnail(image: image, size: 120)
                .overlay(alignment: .topTrailing) {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain).padding(4)
                }
            HStack(spacing: 2) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                Button(action: editAlt) {
                    Text(image.altText.isEmpty ? "Alt text" : "Alt ✓").font(.caption2)
                }
                Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(index == count - 1)
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct AltTextSheet: View {
    @Bindable var image: PostImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Thumbnail(image: image, size: 200)
            Text("Describe the picture for screen readers").font(.headline)
            TextField("Alt text", text: $image.altText, axis: .vertical).lineLimit(3...6)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Inserts a tag for a saved person or company.
struct MentionMenu: View {
    let contacts: [Contact]
    let insert: (String) -> Void

    var body: some View {
        Menu {
            if contacts.isEmpty {
                Text("Add people and companies in “People & Companies”")
            }
            ForEach(ContactKind.allCases, id: \.self) { kind in
                let group = contacts.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind == .person ? "People" : "Companies") {
                        ForEach(group) { contact in
                            Button {
                                insert(contact.mentionToken)
                            } label: {
                                Label(contact.name + (contact.urn.isEmpty ? " (tag by hand)" : ""), systemImage: kind.symbol)
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Tag", systemImage: "at")
        }
        .fixedSize()
    }
}

/// Roughly how the post reads on LinkedIn: tags highlighted, the first comment below.
struct PostPreview: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(LinkedInAccount.shared.memberName ?? "You").font(.headline)
                    Text(post.scheduledAt?.formatted(date: .abbreviated, time: .shortened) ?? "Now")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(rendered(post.text)).textSelection(.enabled)
            if let video = post.videoFileName {
                VideoThumbnail(fileName: video, size: 300)
            } else if !post.orderedImages.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 4)], spacing: 4) {
                    ForEach(post.orderedImages.prefix(4)) { image in
                        Thumbnail(image: image, size: 140)
                    }
                }
                if post.images.count > 4 {
                    Text("+\(post.images.count - 4) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            if post.hasComment {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "bubble.left").foregroundStyle(.secondary)
                    Text(rendered(post.commentText)).font(.callout)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func rendered(_ text: String) -> AttributedString {
        var out = AttributedString()
        for segment in LittleText.segments(text) {
            switch segment {
            case .text(let s):
                out += AttributedString(s)
            case .mention(let name, let urn):
                var a = AttributedString(name)
                a.foregroundColor = urn == nil ? .orange : .accentColor
                a.font = .body.weight(.semibold)
                out += a
            }
        }
        return out
    }
}

/// Length and size of the attached video.
private struct VideoFacts: View {
    let fileName: String
    @State private var duration: Double?

    var body: some View {
        let url = VideoStore.directory.appendingPathComponent(fileName)
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        HStack(spacing: 12) {
            if let duration {
                Label(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)), systemImage: "clock")
            }
            Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "internaldrive")
        }
        .font(.caption).foregroundStyle(.secondary)
        .task(id: fileName) { duration = await VideoStore.duration(fileName) }
    }
}

/// A video picked in Photos, copied to a temporary file (videos are too big to load as Data).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
