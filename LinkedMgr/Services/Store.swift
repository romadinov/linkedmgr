import Foundation
import SwiftData
import notify

/// The database shared by the app and the background agent.
enum Store {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LinkedMgr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LinkedMgr.store")
    }()

    static func container() throws -> ModelContainer {
        try ModelContainer(for: Post.self, PostImage.self, Contact.self,
                           configurations: ModelConfiguration(url: url))
    }
}

/// Cross-process pings between the app and the agent (Darwin notifications carry no data).
enum Signal: String {
    /// Agent → app: posts changed in the database, reload.
    case changed = "com.ideahelix.linkedmgr.changed"
    /// App → agent: something is due now (Publish Now, Retry), don't wait for the next tick.
    case kick = "com.ideahelix.linkedmgr.kick"

    func post() {
        notify_post(rawValue)
    }

    /// Calls `handler` on the main queue each time the signal is posted.
    func observe(_ handler: @escaping @MainActor () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(rawValue, &token, .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
