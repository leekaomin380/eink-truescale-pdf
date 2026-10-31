import SwiftUI
import AppKit
import IOKit

// 「快捷键投递」页（左栏排版，右栏用法）、全局的连接状态与最近投递，以及主窗口内的「设置」页。

/// 一条已通过回读校验的投递，由直连工具写入 Direct/history.jsonl。
struct DeliveryRecord: Decodable, Identifiable {
    let time: String
    let name: String
    let source: String
    let opened: Bool
    /// direct：直连并回读校验；official：直连不可用时经 QUADERNO PC App 投递（无回读）。
    let via: String?
    var id: String { time + name }

    var date: Date? { ISO8601DateFormatter().date(from: time) }

    var sourceLabel: String {
        switch source {
        case "clipboard": "⌃1"
        case "finder": L("Finder 右键")
        default: L("App 内发送")
        }
    }
}

/// USB 连接状态与最近投递。App 运行时每 3 秒轮询；两项都是本地读取，不访问设备。
@MainActor
final class QuickSendMonitor: ObservableObject {
    static let shared = QuickSendMonitor()
    @Published private(set) var usbModel: String?
    @Published private(set) var history: [DeliveryRecord] = []
    private var timer: Timer?
    private var viewers = 0

    private let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quaderno Converter/Direct/history.jsonl")

    func start() {
        viewers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in QuickSendMonitor.shared.refresh() }
        }
    }

    func stop() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        let model = QuadernoUSB.connectedModel()
        if model != usbModel { usbModel = model }
        let records = loadHistory()
        if records.map(\.id) != history.map(\.id) { history = records }
    }

    private func loadHistory() -> [DeliveryRecord] {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(DeliveryRecord.self, from: Data($0.utf8)) }
            .reversed().prefix(10).map { $0 }
    }
}

enum QuadernoUSB {
    /// Fujitsu（0x04c5）FMVDP 系列在 USB 总线上时返回型号，例如 FMVDP51。
    static func connectedModel() -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let vendor = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if vendor == 0x04c5, let name, name.hasPrefix("FMVDP") { return name }
        }
        return nil
    }

    static func displayName(for model: String) -> String {
        switch model {
        case "FMVDP51": "QUADERNO A5 (FMVDP51)"
        case "FMVDP41": "QUADERNO A4 (FMVDP41)"
        default: "QUADERNO (\(model))"
        }
    }
}

// MARK: - 主窗口页面切换

/// 主窗口当前显示的页面：nil 为输入页（文件 / 文本 / 网页 / 快捷键投递）。
enum MainPage { case settings, about, files }

/// 菜单命令与工具栏共用的页面状态。
@MainActor
final class MainNavigation: ObservableObject {
    static let shared = MainNavigation()
    @Published var page: MainPage?
    @Published var showSetupGuide = false

    func show(_ target: MainPage) {
        page = target
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 快捷键投递页左栏：排版

struct QuickSendSidebar: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("排版") { ClipboardLayoutSettings() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

/// 分组标题 + 圆角容器，设置页与快捷键投递页共用。
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 0) { content }
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }
}

// MARK: - 设置页：设备、投递入口、常见问题

struct AppSettingsView: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared
    @State private var address = "Android.local"
    @State private var connecting = false
    @State private var connectionMessage = ""
    @State private var checking = false
    @State private var checkPassed: Bool?
    @State private var checkOutput = ""
    @State private var showSetup = false

    private var scriptURL: URL? { Bundle.main.url(forResource: "deliver", withExtension: "sh") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text("设置").font(.largeTitle.weight(.semibold))
                    Spacer()
                    Button("设置向导…") { MainNavigation.shared.showSetupGuide = true }
                }
                SettingsSection("语言") { LanguageSettings() }
                SettingsSection("设备") { deviceGroup }
                SettingsSection("投递入口") { entriesGroup }
                SettingsSection("常见问题") { faq }
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showSetup) { HotkeySetupSheet(scriptURL: scriptURL) }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var deviceGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(monitor.usbModel == nil ? Color.red : Color.green).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    if let model = monitor.usbModel {
                        Text("已连接").fontWeight(.semibold)
                        Text(verbatim: QuadernoUSB.displayName(for: model) + " · USB")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("USB 未连接").fontWeight(.semibold)
                        Text("请插好 USB 线并唤醒设备；使用 Wi-Fi 时运行自检确认")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                if let checkPassed, !checking {
                    Image(systemName: checkPassed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(checkPassed ? .green : .orange)
                        .help(checkPassed ? L("本机检查通过") : L("检查未通过，请查看详情"))
                }
                Button("自检") { runCheck() }.disabled(checking || connecting || scriptURL == nil)
            }
            .padding(12)
            if checkPassed == false {
                DisclosureGroup("自检详情") {
                    Text(checkOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption).padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider().padding(.leading, 12)
            DisclosureGroup("连接设置") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("设备地址") { TextField("设备地址", text: $address).labelsHidden() }
                    HStack {
                        Text("USB 通常为 Android.local；Wi-Fi 填设备 IP").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(connecting ? L("连接中…") : L("迁移现有配对…")) { importPairing() }
                            .disabled(connecting || checking)
                    }
                    if !connectionMessage.isEmpty { Text(connectionMessage).font(.callout) }
                }
                .padding(.top, 8)
            }
            .padding(12)
        }
    }

    private var entriesGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(verbatim: "⌃1").font(.caption.weight(.semibold)).frame(width: 34, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text("剪贴板快捷键")
                    Text("由 macOS「快捷指令」提供").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("设置快捷键…") { showSetup = true }.buttonStyle(.link).disabled(scriptURL == nil)
            }
            .padding(12)
            Divider().padding(.leading, 12)
            HStack(spacing: 12) {
                Image(systemName: "folder").frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finder 右键")
                    Text("PDF、Markdown、TXT · 无需设置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("已启用").foregroundStyle(.green)
            }
            .padding(12)
        }
    }

    private var faq: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("提示「no such file or directory」？").fontWeight(.medium)
            Text("通常是快捷指令仍引用已经移动的源码目录。重新复制本页命令并替换旧命令即可。命令使用 App 内置脚本，归档源码不会影响它；移动或重命名 App 后，需要重新复制命令。")
            Text("Ctrl+1 自动取内容自带标题、Markdown 标题或第一句正文作为文件名，并附加时间。App 主窗口仍使用手动标题。设备已有同名文件时另存新文件，避免覆盖手写批注。")
            Text("直连失败时保留本地 PDF，通知中显示路径；重新投递前可先检查设备，避免重复发送。")
            Text("由本 App 直接提供，无需安装。菜单项未出现时，请在「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹」中勾选「发送到 QUADERNO」。")
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importPairing() {
        connecting = true
        Task {
            let result = await DirectDelivery.run(["import-pairing", "--address", address])
            connectionMessage = result.message
            connecting = false
        }
    }

    private func runCheck() {
        checking = true
        checkPassed = nil
        Task {
            let result = await SelfCheck.run()
            checkPassed = result.passed
            checkOutput = result.output
            checking = false
            monitor.refresh()
        }
    }
}

// MARK: - 右栏：用法与最近投递

struct QuickSendOverview: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                // 窄窗口时三步改为竖排，避免横排超出右栏被两侧裁切。
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) { steps(arrow: arrow) }
                    VStack(spacing: 18) { steps(arrow: EmptyView()) }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private func steps<Arrow: View>(arrow: Arrow) -> some View {
        step(icon: Image(systemName: "doc.on.doc"), title: "复制文字", detail: "任何应用中的 Markdown 或纯文本")
        arrow
        step(icon: Text(verbatim: "⌃1").font(.system(size: 22, weight: .semibold)), title: "按 ⌃1", detail: "自动命名，排版成 PDF")
        arrow
        step(icon: Image(systemName: "ipad"), title: "在设备上打开", detail: "存入 Received，校验后自动打开")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 24)
    }

    private func step<Icon: View>(icon: Icon, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            icon.font(.system(size: 26)).frame(width: 64, height: 64)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            Text(title).fontWeight(.semibold)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 150)
    }
}

// MARK: - ⌃1 设置向导

struct HotkeySetupSheet: View {
    let scriptURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var command: String {
        guard let path = scriptURL?.path else { return "" }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("设置 ⌃1 快捷键").font(.title2.weight(.semibold))
                Text("macOS 不允许 App 替你绑定全局快捷键，需要在「快捷指令」里做一次。大约 1 分钟。")
                    .foregroundStyle(.secondary)
            }
            step(1, "复制投递命令") {
                HStack {
                    Button(copied ? L("已复制命令") : L("复制命令"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(command.isEmpty)
                    Text("会替换当前剪贴板").font(.caption).foregroundStyle(.secondary)
                }
            }
            step(2, "新建快捷指令，粘贴命令") {
                Text("添加「运行 Shell 脚本」操作，Shell 选 /bin/zsh，粘贴刚才复制的命令。")
                    .foregroundStyle(.secondary)
                Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                }
            }
            step(3, "绑定 ⌃1") {
                Text("在快捷指令详情中打开「用作快速操作」，添加键盘快捷键 ⌃1。").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("设置好后，复制一段文字按 ⌃1 试一下").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private func step<Content: View>(_ number: Int, _ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: "\(number)").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                .frame(width: 24, height: 24).background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).fontWeight(.semibold)
                content()
            }
        }
    }
}

// MARK: - 界面语言

/// App 自身的界面语言（AppLanguage），重新启动后生效；直连工具与 Ctrl+1 读取同一偏好。
struct LanguageSettings: View {
    private static let choices: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"), ("en", "English"), ("ja", "日本語"),
    ]
    private let launchLanguage = AppLanguage.chosen ?? ""
    @State private var language = AppLanguage.chosen ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("界面语言")
                Spacer()
                Picker("界面语言", selection: $language) {
                    Text("跟随系统").tag("")
                    ForEach(Self.choices, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if language != launchLanguage {
                HStack {
                    Text("重新启动 App 后生效").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即重新启动") { relaunch() }
                }
            }
        }
        .padding(12)
        .onChange(of: language) { _, value in
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: AppLanguage.key)
            } else {
                UserDefaults.standard.set(value, forKey: AppLanguage.key)
            }
        }
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 自检与配对状态（设置页与设置向导共用）

enum SelfCheck {
    /// deliver.sh --check：渲染测试 PDF、认证并读取目录，不上传文件。
    static func run() async -> (passed: Bool, output: String) {
        guard let script = Bundle.main.url(forResource: "deliver", withExtension: "sh") else {
            return (false, L("投递脚本缺失，请重新安装完整 App。"))
        }
        return await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, "--check"]
            process.environment = helperEnvironment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
}

enum Pairing {
    /// 直连工具保存配对的位置（目录名沿用旧 App 名，避免迁移凭据）。
    static var isPaired: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quaderno Converter/Direct/connection.json").path)
    }
    static var officialAppInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/QUADERNO PC App.app")
    }
    static let guideDismissedKey = "setupGuideDismissed"
}

// MARK: - 首次使用的设置向导

struct SetupGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = QuickSendMonitor.shared
    @State private var paired = Pairing.isPaired
    @State private var importing = false
    @State private var importMessage = ""
    @State private var checking = false
    @State private var checkPassed: Bool?
    @State private var checkOutput = ""
    @State private var showHotkey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("开始使用 TrueScale for QUADERNO").font(.title2.weight(.semibold))
                Text("三步完成设置。完成后，投递不再需要打开 QUADERNO PC App。").foregroundStyle(.secondary)
            }
            step(1, done: monitor.usbModel != nil, "用 USB 线连接 QUADERNO 并唤醒") {
                if let model = monitor.usbModel {
                    Text(verbatim: QuadernoUSB.displayName(for: model) + " · USB").foregroundStyle(.secondary)
                } else {
                    Text("连接后这里会自动变为已连接。").foregroundStyle(.secondary)
                }
            }
            step(2, done: paired, "导入现有配对") {
                Text(Pairing.officialAppInstalled
                     ? L("读取 QUADERNO PC App 在这台 Mac 上建立的配对，只需一次。")
                     : L("需要先安装 QUADERNO PC App，并与设备配对一次。"))
                    .foregroundStyle(.secondary)
                if !paired {
                    HStack {
                        Button(importing ? L("连接中…") : L("导入配对")) { importPairing() }
                            .disabled(importing || !Pairing.officialAppInstalled)
                        if importing { ProgressView().controlSize(.small) }
                    }
                }
                if !importMessage.isEmpty { Text(importMessage).font(.callout) }
            }
            step(3, done: checkPassed == true, "运行自检") {
                Text("渲染一份测试 PDF 并连接设备，不上传文件。").foregroundStyle(.secondary)
                HStack {
                    Button(checking ? L("正在自检…") : L("自检")) { runCheck() }.disabled(checking || !paired)
                    if checking { ProgressView().controlSize(.small) }
                }
                if checkPassed == false {
                    DisclosureGroup("自检详情") {
                        Text(checkOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                }
            }
            step(4, done: false, optional: true, "设置 ⌃1 快捷键（可选）") {
                Text("Finder 右键投递无需设置，已经可以使用。").foregroundStyle(.secondary)
                Button("设置快捷键…") { showHotkey = true }
            }
            Divider()
            HStack {
                Button("以后再说") { close() }
                Spacer()
                Button("完成") { close() }.keyboardShortcut(.defaultAction).disabled(!paired)
            }
        }
        .padding(28)
        .frame(width: 540)
        .sheet(isPresented: $showHotkey) {
            HotkeySetupSheet(scriptURL: Bundle.main.url(forResource: "deliver", withExtension: "sh"))
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func step<Content: View>(_ number: Int, done: Bool, optional: Bool = false, _ title: LocalizedStringKey,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(optional ? 0.08 : 0.12))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(number)").font(.callout.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).fontWeight(.semibold)
                content()
            }
        }
    }

    private func importPairing() {
        importing = true
        Task {
            let result = await DirectDelivery.run(["import-pairing", "--address", "Android.local"])
            importMessage = result.message
            paired = Pairing.isPaired
            importing = false
        }
    }

    private func runCheck() {
        checking = true
        checkPassed = nil
        Task {
            let result = await SelfCheck.run()
            checkPassed = result.passed
            checkOutput = result.output
            checking = false
        }
    }

    private func close() {
        UserDefaults.standard.set(true, forKey: Pairing.guideDismissedKey)
        dismiss()
    }
}

/// 窗口工具栏中的全局 USB 连接状态；点击打开设置页。
struct USBStatusBadge: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        Button { MainNavigation.shared.show(.settings) } label: {
            HStack(spacing: 6) {
                Circle().fill(monitor.usbModel == nil ? Color.red : Color.green).frame(width: 8, height: 8)
                if let model = monitor.usbModel {
                    Text(verbatim: QuadernoUSB.displayName(for: model))
                } else {
                    Text("USB 未连接")
                }
            }
            .font(.callout)
        }
        .help(L("设备设置…"))
        .onAppear { monitor.start() }
    }
}

// MARK: - 最近投递（全局：⌃1、Finder 右键、App 内发送、降级投递都会记录）

struct RecentDeliveriesButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Label("最近投递", systemImage: "clock.arrow.circlepath") }
            .help(L("最近投递"))
            .popover(isPresented: $showing, arrowEdge: .bottom) { RecentDeliveriesList().frame(width: 400) }
    }
}

struct RecentDeliveriesList: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近投递").font(.headline)
            if monitor.history.isEmpty {
                Text("还没有投递记录。投递的文件会显示在这里。").foregroundStyle(.secondary)
            } else {
                ForEach(Array(monitor.history.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: record.via == "official" ? "arrow.triangle.branch" : "checkmark")
                            .foregroundStyle(record.via == "official" ? Color.orange : Color.green).fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: record.name).lineLimit(1).truncationMode(.middle).help(record.name)
                            Text(verbatim: detail(for: record)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .onAppear { monitor.refresh() }
    }

    private func detail(for record: DeliveryRecord) -> String {
        let when = record.date.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? record.time
        let route = record.via == "official" ? L("经 QUADERNO PC App") : L("回读校验通过")
        return [when, record.sourceLabel, route].joined(separator: " · ")
    }
}
