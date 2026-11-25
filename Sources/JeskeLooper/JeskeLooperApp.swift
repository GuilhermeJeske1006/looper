import AppKit
import LooperCore
import SwiftUI

extension Notification.Name {
    static let showLooperHelp = Notification.Name("JeskeLooper.showHelp")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LooperController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.needsGracefulTermination {
            // Finish and save the take before quitting.
            model.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        model.shutdown()
        return .terminateNow
    }
}

@main
enum Launcher {
    static func main() {
        if let directory = ProcessInfo.processInfo.environment["JESKE_SNAPSHOT_DIR"] {
            MainActor.assumeIsolated { UISnapshot.run(into: URL(fileURLWithPath: directory)) }
        } else {
            JeskeLooperApp.main()
        }
    }
}

struct JeskeLooperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LooperController()
    @StateObject private var shortcuts = ShortcutCenter()

    var body: some Scene {
        Window("Jeske Looper", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(shortcuts)
                .background(WindowAccessor { window in shortcuts.mainWindow = window })
                .onAppear {
                    appDelegate.model = model
                    model.start()
                    shortcuts.attach(model)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.recheckPermission()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("Ajuda do Jeske Looper") {
                    NotificationCenter.default.post(name: .showLooperHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(shortcuts)
        }
    }
}
