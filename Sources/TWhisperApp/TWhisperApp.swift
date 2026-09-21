import SwiftUI
import AppKit
import TWhisperKit

@main
struct TWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AudioRecorder.cleanupStaleFiles()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForQuit()
    }
}

