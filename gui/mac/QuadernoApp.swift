import SwiftUI

@main
struct QuadernoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(\.locale, AppLanguage.locale)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("关于 Quaderno Converter")) { MainNavigation.shared.show(.about) }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L("设置…")) { MainNavigation.shared.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private let finderService = FinderSendService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = finderService
        NSUpdateDynamicServices()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Finder 右键「发送到 QUADERNO」（Info.plist NSServices）。PDF 原样上传，Markdown / TXT 按 Ctrl+1 排版渲染。
final class FinderSendService: NSObject {
    @objc func sendToQuaderno(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let script = Bundle.main.url(forResource: "deliver", withExtension: "sh") else {
            error.pointee = L("未收到可投递的文件。") as NSString
            return
        }
        // Return immediately; deliver.sh reports success or failure as a notification.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, "--files"] + urls.map(\.path)
            process.environment = helperEnvironment()
            try? process.run()
            process.waitUntilExit()
        }
    }
}
