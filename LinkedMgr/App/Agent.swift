import Foundation
import ServiceManagement
import SwiftData

/// The background publisher: this same executable, launched by launchd with `--agent`.
///
/// It's registered from Settings via `SMAppService` using the plist bundled at
/// Contents/Library/LaunchAgents. Being the same binary as the app means it can read the
/// LinkedIn token from the Keychain without prompts. It deliberately never touches
/// NSApplication, so it doesn't register as a running "LinkedMgr" and opening the app
/// still launches the window normally.
enum Agent {
    static let plistName = "com.ideahelix.linkedmgr.agent.plist"
    static var service: SMAppService { .agent(plistName: plistName) }

    @MainActor
    static func run() -> Never {
        agentLog.info("Agent starting")
        let container: ModelContainer
        do {
            container = try Store.container()
        } catch {
            agentLog.fault("Can't open the database: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
        let engine = PublishEngine(container: container)
        engine.recoverInterrupted()

        let launchedBinary = executableDate()
        let timer = Timer(timeInterval: PublishEngine.tickInterval, repeats: true) { _ in
            // After the app is rebuilt or updated, exit so launchd relaunches the new code.
            if executableDate() != launchedBinary {
                agentLog.info("App updated; restarting agent")
                exit(0)
            }
            Task { @MainActor in await engine.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        Signal.kick.observe { Task { await engine.tick() } }
        Task { await engine.tick() }

        // Timers don't fire during sleep; the first tick after wake catches up on anything due.
        RunLoop.main.run()
        exit(0)
    }

    private static func executableDate() -> Date? {
        Bundle.main.executablePath.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date
        }
    }
}
