import SwiftUI

@main
struct QuadernoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        LegacyPreferences.migrate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(\.locale, AppLanguage.locale)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("关于 TrueScale for QUADERNO")) { MainNavigation.shared.show(.about) }
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

/// bundle ID 曾为 com.eink-truescale.gui（与 App Store 版 TrueScalePDF 相同，2026-10-31 更换）。
/// 首次启动时从旧偏好文件复制排版、界面语言等设置。直接读文件：按域名读取会落到
/// 同 ID 的 App Store 版沙盒容器，而不是本 App 曾经使用的偏好。
enum LegacyPreferences {
    private static let doneKey = "migratedFromLegacyBundleID"

    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.eink-truescale.gui.plist")
        guard let data = try? Data(contentsOf: url),
              let legacy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for (key, value) in legacy where key.hasPrefix("pref.") || key == "isAdvancedExpanded" || key == AppLanguage.key {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
    }
}
