import AppKit
import SwiftData
import SwiftUI
import UserNotifications

@main
struct LinkedMgrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Post.self, PostImage.self, Contact.self)
        } catch {
            fatalError("Couldn't open the LinkedMgr database: \(error)")
        }
        // Unit tests run inside the app; they must never publish anything.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let container = container
        Task { @MainActor in Publisher.shared.start(container: container) }
    }

    var body: some Scene {
        Window("LinkedMgr", id: "main") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .modelContainer(container)
        .commands {
            ImportFromDevicesCommands()
            CommandGroup(replacing: .newItem) {
                NewPostButton()
            }
        }

        MenuBarExtra {
            MenuBarView()
                .modelContainer(container)
        } label: {
            Image(systemName: "paperplane.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(container)
        }
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
