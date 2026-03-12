import AppKit
import SwiftUI

@main
struct DeepVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("DeepVoice Console") {
            DevConsoleView(state: appDelegate.consoleState, actions: appDelegate.consoleActions)
        }
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = VoiceAgentRuntime()

    var consoleState: DevConsoleState { runtime.consoleState }
    var consoleActions: DevConsoleActions { runtime.consoleActions }

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.shutdown()
    }
}
