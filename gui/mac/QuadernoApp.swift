import SwiftUI

@main
struct QuadernoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                ShortcutDeliveryMenu()
            }
        }
        Window("快捷投递", id: "shortcut-delivery") {
            ShortcutDeliveryView()
        }
        .defaultSize(width: 640, height: 710)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
