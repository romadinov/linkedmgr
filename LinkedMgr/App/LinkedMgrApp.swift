import AppKit
import SwiftData
import SwiftUI
import UserNotifications

/// Launched from main.swift unless running as the background agent.
struct LinkedMgrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var store = StoreRefresher.shared

    var body: some Scene {
        Window("LinkedMgr", id: "main") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .modelContext(store.context)
        .commands {
            ImportFromDevicesCommands()
            CommandGroup(replacing: .newItem) {
                NewPostButton()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .modelContext(store.context)
        } label: {
            Image(systemName: "paperplane.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContext(store.context)
        }
    }
}

/// The app's view of the shared database. The agent writes to the same store from another
/// process; when it signals a change, a fresh context replaces the stale one so lists update.
@MainActor @Observable
final class StoreRefresher {
    static let shared = StoreRefresher()

    let container: ModelContainer
    private(set) var context: ModelContext

    private init() {
        do {
            container = try Store.container()
        } catch {
            fatalError("Couldn't open the LinkedMgr database: \(error)")
        }
        context = Self.makeContext(container)
        Signal.changed.observe { StoreRefresher.shared.reload() }
    }

    func reload() {
        try? context.save()
        context = Self.makeContext(container)
    }

    /// Saves and asks the agent to act now rather than on its next tick.
    func commitAndKick() {
        try? context.save()
        Signal.kick.post()
    }

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = true
        return context
    }
}

/// Keeps LinkedMgr alive in the menu bar after its window closes, so posts still go out.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }
}

/// Posted to ask the main window to create and select a new post.
extension Notification.Name {
    static let newPost = Notification.Name("LinkedMgr.newPost")
}

struct NewPostButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Post") {
            openWindow(id: "main")
            NotificationCenter.default.post(name: .newPost, object: nil)
        }
        .keyboardShortcut("n")
    }
}
