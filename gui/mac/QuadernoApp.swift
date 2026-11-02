import SwiftUI

@main
struct QuadernoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        LegacyPreferences.migrate()
    }

    var body: some Scene {
        WindowGroup(id: MainWindow.id) {
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
        // 关闭窗口后 App 留在菜单栏，全局快捷键与 USB 自动切换继续工作。
        MenuBarExtra {
            MenuBarMenu().environment(\.locale, AppLanguage.locale)
        } label: {
            MenuBarLabel()
        }
    }
}

/// 菜单栏图标。顺带把 SwiftUI 的 openWindow 交给 AppDelegate：没有窗口时从 Dock / Finder 再次打开要用它。
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "q.square")
            .onAppear { MainWindow.opener = openWindow }
    }
}

/// 常驻：关闭最后一个窗口不退出，Dock 图标收起，只留菜单栏图标（「退出」在菜单栏菜单里）。
/// 以下情况启动时不开窗口：系统为 Finder 右键投递拉起 App、登录时自动启动。
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let finderService = FinderSendService()
    /// 最近一个在前台的其他 App（通常是 Finder），右键投递后把前台还给它。
    private var previousApp: NSRunningApplication?
    private var launchedAsLoginItem = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 登录项启动时，打开 App 的 Apple 事件带 keyAELaunchedAsLogInItem。
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = finderService
        NSUpdateDynamicServices()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app != .current { Task { @MainActor in self?.previousApp = app } }
        }
        // 系统在送来服务请求前会把本 App 切到前台（2026-11-02 实测：请求到达时 frontmostApplication
        // 已是本 App，随即 didBecomeActive）。投递不需要界面，所以把前台还给原来的 App。
        finderService.onRequest = { [weak self] wasActive in
            guard !wasActive, let app = self?.previousApp, !app.isTerminated else { return }
            DispatchQueue.main.async { app.activate() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // 关闭动画结束后窗口才算不可见。
            DispatchQueue.main.async { MainWindow.updatePolicy() }
        }
        GlobalHotkeys.shared.start()
        // 常驻期间一直监视 USB：插上设备即切换到网卡模式，不必打开窗口。
        QuickSendMonitor.shared.start()

        // 系统为执行服务、打开文件等拉起 App 时，此键为 false；双击、Dock、open 命令为 true。
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !isDefault || launchedAsLoginItem {
            if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
            NSApp.setActivationPolicy(.accessory)
            closeWindows()
            // SwiftUI 可能在本回调之后才建出首个窗口。
            DispatchQueue.main.async { self.closeWindows() }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 没有窗口时（菜单栏常驻状态）再次打开 App：重新开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MainWindow.visibleWindows.isEmpty {
            MainWindow.show()
            return false
        }
        return true
    }

    private func closeWindows() {
        NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() }
    }
}

/// Finder 右键「投递到 QUADERNO」（Info.plist NSServices）。PDF 原样上传，Markdown / TXT 按 ⌃1 排版渲染，
/// EPUB 按书排版。不激活 App、不开窗口：结果由 deliver.sh 以系统通知报告。
final class FinderSendService: NSObject {
    /// 收到请求时调用；参数为本 App 此前是否已在前台（用户自己正在用它）。
    var onRequest: ((Bool) -> Void)?

    @objc func sendToQuaderno(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        onRequest?(NSApp.isActive)
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

