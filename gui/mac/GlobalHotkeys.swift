import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// 全局快捷键：⌃1 投递剪贴板、⌃2 截屏。用 Carbon 的 RegisterEventHotKey 注册，
/// 不需要辅助功能权限，也不经过「快捷指令」。代价是 App 必须在运行，所以 App 常驻菜单栏。
/// （2026-11-02 起取代「在快捷指令里粘贴命令」的做法：那条路要用户手动设置，App 改名后命令还会失效。）
enum HotkeyAction: String, CaseIterable, Identifiable {
    case deliver, screenshot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .deliver: L("投递剪贴板")
        case .screenshot: L("截屏")
        }
    }

    var defaultCombo: HotkeyCombo {
        switch self {
        case .deliver: HotkeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey))
        case .screenshot: HotkeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(controlKey))
        }
    }

    /// deliver.sh 的参数：无参数为剪贴板投递。
    var scriptArguments: [String] { self == .screenshot ? ["--screenshot"] : [] }
}

/// 一个按键组合。modifiers 用 Carbon 位（controlKey / optionKey / cmdKey / shiftKey）。
struct HotkeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 从按键事件构造；至少要有 ⌃ ⌥ ⌘ 之一，只有 ⇧ 或没有修饰键的组合会吞掉正常输入。
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    /// 按当前键盘布局取键名（非 US 布局下数字行也正确）。
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ code: UInt32) -> String {
        if let name = specialKeys[Int(code)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

@MainActor
final class GlobalHotkeys: ObservableObject {
    static let shared = GlobalHotkeys()

    /// 注册失败（多为已被系统或其他 App 占用）的动作。
    @Published private(set) var conflicts: Set<HotkeyAction> = []
    @Published private(set) var combos: [HotkeyAction: HotkeyCombo] = [:]
    @Published private(set) var enabled: [HotkeyAction: Bool] = [:]
    /// 录入新组合期间暂停全部快捷键，否则按下旧组合会直接触发投递。
    var paused = false { didSet { paused ? unregisterAll() : registerAll() } }

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var running = 0

    private init() {
        for action in HotkeyAction.allCases {
            let defaults = UserDefaults.standard
            if let data = defaults.data(forKey: Self.comboKey(action)),
               let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
                combos[action] = combo
            } else {
                combos[action] = action.defaultCombo
            }
            enabled[action] = defaults.object(forKey: Self.enabledKey(action)) as? Bool ?? true
        }
    }

    private static func comboKey(_ action: HotkeyAction) -> String { "Hotkey.\(action.rawValue).combo" }
    private static func enabledKey(_ action: HotkeyAction) -> String { "Hotkey.\(action.rawValue).enabled" }

    func start() {
        installHandler()
        registerAll()
    }

    func set(_ combo: HotkeyCombo, for action: HotkeyAction) {
        combos[action] = combo
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: Self.comboKey(action))
        }
        registerAll()
    }

    func setEnabled(_ value: Bool, for action: HotkeyAction) {
        enabled[action] = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey(action))
        registerAll()
    }

    func resetToDefault(_ action: HotkeyAction) {
        UserDefaults.standard.removeObject(forKey: Self.comboKey(action))
        combos[action] = action.defaultCombo
        registerAll()
    }

    /// 两个动作不能用同一组合。
    func isTaken(_ combo: HotkeyCombo, except action: HotkeyAction) -> Bool {
        HotkeyAction.allCases.contains { $0 != action && combos[$0] == combo && enabled[$0] == true }
    }

    private func registerAll() {
        unregisterAll()
        guard !paused else { return }
        var failed: Set<HotkeyAction> = []
        for (index, action) in HotkeyAction.allCases.enumerated() where enabled[action] == true {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5453_514B), id: UInt32(index))  // 'TSQK'
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref } else { failed.insert(action) }
        }
        if failed != conflicts { conflicts = failed }
    }

    private func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let actions = HotkeyAction.allCases
            guard Int(id.id) < actions.count else { return OSStatus(eventNotHandledErr) }
            let action = actions[Int(id.id)]
            Task { @MainActor in GlobalHotkeys.shared.perform(action) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// 与 Finder 右键一样在后台运行 deliver.sh；结果由脚本以系统通知报告，不打开窗口。
    func perform(_ action: HotkeyAction) {
        guard let script = Bundle.main.url(forResource: "deliver", withExtension: "sh") else { return }
        var arguments = [script.path] + action.scriptArguments
        var clipboardFiles: [URL] = []
        if action == .deliver {
            // 剪贴板必须由本进程读：macOS 15.4 起程序读取通用剪贴板要经用户授权（首次弹出系统提示，
            // 可在「系统设置 → 隐私与安全性 → 粘贴」中改为始终允许）；子进程的 pbpaste 只会读到空内容。
            // 读不到时仍交给脚本，由它报告「剪贴板为空」。
            let pasteboard = NSPasteboard.general
            let text = pasteboard.string(forType: .string) ?? ""
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("truescale-clipboard-\(UUID().uuidString)")
            let file = base.appendingPathExtension("md")
            if (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil {
                clipboardFiles.append(file)
                arguments += ["--clipboard-file", file.path]
                // 富文本风味只作旁路输入，不替换纯文本正文：helper 只有在能定位
                // 明确的 <table> 结构时才用它重建表格，其余正文逐字保留。
                let htmlType = NSPasteboard.PasteboardType("public.html")
                if let data = pasteboard.data(forType: htmlType),
                   let html = String(data: data, encoding: .utf8), !html.isEmpty,
                   (try? html.write(to: base.appendingPathExtension("html"),
                                    atomically: true, encoding: .utf8)) != nil {
                    let htmlFile = base.appendingPathExtension("html")
                    clipboardFiles.append(htmlFile)
                    arguments += ["--clipboard-html", htmlFile.path]
                }
            }
        }
        running += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = arguments
            process.environment = helperEnvironment()
            _ = ProcessRunner.run(process, mode: .none, timeout: 3600)
            for clipboardFile in clipboardFiles { try? FileManager.default.removeItem(at: clipboardFile) }
            DispatchQueue.main.async { self.running -= 1 }
        }
    }
}

/// 登录时启动：快捷键只在 App 运行时有效，开机后需要 App 自动常驻。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 返回失败原因；成功为 nil。
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - 设置界面

/// 一行快捷键设置：开关、组合（点击后录入）、冲突提示。
struct HotkeyRow: View {
    let action: HotkeyAction
    @ObservedObject private var hotkeys = GlobalHotkeys.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(get: { hotkeys.enabled[action] ?? true },
                                     set: { hotkeys.setEnabled($0, for: action) })) {
                    Text(verbatim: action.title)
                }
                Spacer()
                Button { recording ? stopRecording() : startRecording() } label: {
                    Text(verbatim: recording ? L("请按下新的快捷键…") : (hotkeys.combos[action]?.display ?? ""))
                        .font(.callout.weight(.semibold)).frame(minWidth: 90)
                }
                .disabled(hotkeys.enabled[action] == false)
                .help(L("点击后按下新的组合；Esc 取消"))
                if hotkeys.combos[action] != action.defaultCombo {
                    Button(L("恢复默认")) { hotkeys.resetToDefault(action) }.buttonStyle(.link)
                }
            }
            if hotkeys.conflicts.contains(action) {
                Text("这个组合已被系统或其他 App 占用，请换一个。").font(.caption).foregroundStyle(.orange)
            } else if !note.isEmpty {
                Text(verbatim: note).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        note = ""
        recording = true
        hotkeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            guard let combo = HotkeyCombo(event: event) else {
                note = L("需要包含 ⌃、⌥ 或 ⌘ 中的至少一个。")
                return nil
            }
            if hotkeys.isTaken(combo, except: action) {
                note = L("另一个快捷键已经在用这个组合。")
                return nil
            }
            hotkeys.set(combo, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            hotkeys.paused = false
        }
    }
}

/// 设置页「快捷键」分组：两行快捷键 + 登录时启动。
struct HotkeySettings: View {
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(HotkeyAction.allCases) { action in
                HotkeyRow(action: action).padding(12)
                Divider().padding(.leading, 12)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { loginEnabled }, set: { value in
                    loginError = LoginItem.set(value) ?? ""
                    loginEnabled = LoginItem.isEnabled
                })) {
                    Text("登录时启动")
                }
                Text("快捷键在 App 运行时有效。关闭窗口后 App 留在菜单栏；打开此项，开机后也会自动在后台运行。")
                    .font(.caption).foregroundStyle(.secondary)
                if !loginError.isEmpty { Text(verbatim: loginError).font(.caption).foregroundStyle(.orange) }
            }
            .padding(12)
        }
        .onAppear { loginEnabled = LoginItem.isEnabled }
    }
}

// MARK: - 菜单栏

/// 菜单栏图标的菜单：App 没有窗口时，快捷操作和设置都从这里进入。
struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var hotkeys = GlobalHotkeys.shared
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        Text(verbatim: LinkStatus(monitor.link).title + " · " + LinkStatus(monitor.link).detail)
        Divider()
        Button(menuTitle(.deliver)) { hotkeys.perform(.deliver) }
        Button(menuTitle(.screenshot)) { hotkeys.perform(.screenshot) }
        Divider()
        Button(L("打开 TrueScale")) { MainWindow.show(openWindow) }
        Button(L("设置…")) {
            MainWindow.show(openWindow)
            MainNavigation.shared.show(.settings)
        }
        Divider()
        Button(L("退出 TrueScale")) { NSApp.terminate(nil) }
    }

    private func menuTitle(_ action: HotkeyAction) -> String {
        guard hotkeys.enabled[action] == true, let combo = hotkeys.combos[action] else { return action.title }
        return action.title + "    " + combo.display
    }
}

/// 主窗口的开关与 Dock 图标：有窗口时是普通 App，没有窗口时只留菜单栏图标。
@MainActor
enum MainWindow {
    static let id = "main"
    /// 由 SwiftUI 场景提供；AppDelegate（Dock / Finder 再次打开）也要用它重新开窗口。
    static var opener: OpenWindowAction?

    static var visibleWindows: [NSWindow] {
        NSApp.windows.filter { $0.canBecomeMain && $0.isVisible }
    }

    static func show(_ open: OpenWindowAction? = nil) {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            (open ?? opener)?(id: id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 最后一个窗口关闭后收起 Dock 图标；App 继续在菜单栏运行。
    static func updatePolicy() {
        if visibleWindows.isEmpty, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
