import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Query(sort: \Post.scheduledAt) private var posts: [Post]
    @Environment(\.openWindow) private var openWindow
    private var account = LinkedInAccount.shared

    private var upcoming: [Post] {
        posts.filter { $0.status == .scheduled && $0.scheduledAt != nil }.prefix(5).map { $0 }
    }

    private var attentionCount: Int {
        posts.filter { [.failed, .missed].contains($0.status) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountBadge()
            Divider()
            if upcoming.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(.secondary)
            } else {
                Text("Up next").font(.caption).foregroundStyle(.secondary)
                ForEach(upcoming) { post in
                    HStack {
                        Text(post.scheduledAt!.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(post.displayTitle).lineLimit(1)
                    }
                }
            }
            if attentionCount > 0 {
                Label("\(attentionCount) post(s) need attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("Open LinkedMgr") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
