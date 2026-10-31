import SwiftUI
import AppKit
import IOKit

// 「快捷投递」页（左栏连接状态与排版，右栏用法与最近投递）与主窗口内的「设置」页。

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

/// USB 连接状态与最近投递。只在快捷投递页可见时轮询；两项都是本地读取，不访问设备。
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
            .reversed().prefix(5).map { $0 }
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

/// 主窗口当前显示的页面：nil 为输入页（文件 / 文本 / 网页 / 快捷投递）。
enum MainPage { case settings, about }

/// 菜单命令与工具栏共用的页面状态。
@MainActor
final class MainNavigation: ObservableObject {
    static let shared = MainNavigation()
    @Published var page: MainPage?

    func show(_ target: MainPage) {
        page = target
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 快捷投递页左栏：连接状态 + 排版

struct QuickSendSidebar: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Circle().fill(monitor.usbModel == nil ? Color.red : Color.green).frame(width: 8, height: 8)
                if let model = monitor.usbModel {
                    Text(verbatim: QuadernoUSB.displayName(for: model) + " · USB").font(.callout)
                } else {
                    Text("USB 未连接").font(.callout)
                }
                Spacer()
                Button("设备设置…") { MainNavigation.shared.show(.settings) }.buttonStyle(.link)
            }
            SettingsSection("排版") { ClipboardLayoutSettings() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

/// 分组标题 + 圆角容器，设置页与快捷投递页共用。
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
                Text("设置").font(.largeTitle.weight(.semibold))
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
                Button("设置向导…") { showSetup = true }.buttonStyle(.link).disabled(scriptURL == nil)
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
        guard let scriptURL else { return }
        checking = true
        checkPassed = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [scriptURL.path, "--check"]
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
            checkPassed = result.0
            checkOutput = result.1
            checking = false
            monitor.refresh()
        }
    }
}

// MARK: - 右栏：用法与最近投递

struct QuickSendOverview: View {
    @ObservedObject private var monitor = QuickSendMonitor.shared

    var body: some View {
        VStack(spacing: 36) {
            HStack(alignment: .top, spacing: 18) {
                step(icon: Image(systemName: "doc.on.doc"), title: "复制文字", detail: "任何应用中的 Markdown 或纯文本")
                arrow
                step(icon: Text(verbatim: "⌃1").font(.system(size: 22, weight: .semibold)), title: "按 ⌃1", detail: "自动命名，排版成 PDF")
                arrow
                step(icon: Image(systemName: "ipad"), title: "在设备上打开", detail: "存入 Received，校验后自动打开")
            }
            recent
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
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

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近投递").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if monitor.history.isEmpty {
                Text("还没有投递记录。复制一段文字，按 ⌃1 试试。").foregroundStyle(.secondary)
            } else {
                ForEach(Array(monitor.history.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: record.via == "official" ? "arrow.triangle.branch" : "checkmark")
                            .foregroundStyle(record.via == "official" ? Color.orange : Color.green).fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: record.name).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: detail(for: record)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private func detail(for record: DeliveryRecord) -> String {
        let when = record.date.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? record.time
        let route = record.via == "official" ? L("经 QUADERNO PC App") : L("回读校验通过")
        return [when, record.sourceLabel, route].joined(separator: " · ")
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
