import Foundation

if CommandLine.arguments.contains("--agent") {
    MainActor.assumeIsolated { Agent.run() }
} else {
    LinkedMgrApp.main()
}
