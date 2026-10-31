import SwiftUI
import AppKit

struct ShortcutDeliveryMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("快捷投递设置…") { openWindow(id: "shortcut-delivery") }
    }
}

struct ShortcutDeliveryView: View {
    var embedded = false
    @State private var address = "Android.local"
    @State private var connecting = false
    @State private var connectionMessage = ""
    @State private var copied = false
    @State private var checking = false
    @State private var checkOutput = ""
    @State private var checkPassed: Bool?
    @State private var showDetails = false

    private var scriptURL: URL? {
        Bundle.main.url(forResource: "deliver", withExtension: "sh")
    }

    private var command: String {
        guard let path = scriptURL?.path else { return L("投递脚本缺失，请重新安装完整 App。") }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "keyboard").font(.system(size: 32)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("复制文字，按一下即投递").font(.title2.bold())
                        Text("剪贴板 Markdown → 自动命名 PDF → 设备直连").foregroundStyle(.secondary)
                    }
                }
                ClipboardLayoutSettings()
                GroupBox("设备直连") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("通过 USB 或同一局域网直接投递，无需运行 QUADERNO PC App。")
                        HStack {
                            TextField("设备地址", text: $address)
                            Button(connecting ? L("连接中…") : L("迁移现有配对")) {
                                connecting = true
                                Task {
                                    let result = await DirectDelivery.run(["import-pairing", "--address", address])
                                    connectionMessage = result.message
                                    connecting = false
                                }
                            }.disabled(connecting || checking)
                        }
                        Text("当前 Mac 已迁移配对时可直接自检。USB 地址通常为 Android.local；Wi-Fi 请填写设备 IP。首次迁移读取本机已有配对，此后凭据独立保存，不再读取官方 App。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !connectionMessage.isEmpty { Text(connectionMessage).font(.callout) }
                    }.padding(8)
                }
                GroupBox("设置全局快捷键") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("建议使用 ⌃1（Control + 1）。快捷键由 macOS「快捷指令」管理；本 App 不会自动占用它。")
                        step("1", "新建快捷指令", "打开「快捷指令」，新建并命名为「投递到 Quaderno」，添加「运行 Shell 脚本」操作。")
                        step("2", "粘贴下面的命令", "Shell 选择 /bin/zsh，不勾选「以管理员身份运行」。已有快捷指令只需替换原来的命令。")
                        Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button(copied ? L("已复制命令") : L("复制命令"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = true
                            }.disabled(scriptURL == nil)
                            Button("打开快捷指令", systemImage: "arrow.up.forward.app") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                            }
                        }
                        step("3", "绑定并使用", "在快捷指令的详细信息中启用「用作快速操作」，添加键盘快捷键 ⌃1。如与系统快捷键冲突，请改用其他组合。复制需要投递的文字后，再按快捷键。")
                    }.padding(8)
                }
                FinderQuickActionSettings()
                GroupBox("使用前检查") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("唤醒设备并连接 USB，或确保 Mac 与设备处于同一局域网。")
                        HStack {
                            Button(checking ? L("正在自检…") : L("运行自检"), systemImage: "stethoscope") { runCheck() }
                                .disabled(checking || connecting || scriptURL == nil)
                            if checking { ProgressView().controlSize(.small) }
                            if let passed = checkPassed {
                                Label(passed ? L("本机检查通过") : L("检查未通过，请查看详情"),
                                      systemImage: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(passed ? .green : .orange)
                            }
                        }
                        Text("自检检查 PDF 渲染、直连认证和目录读取，不上传文件。实际投递保存到 Received，回读核对后请求设备打开；屏幕显示需以设备为准。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !checkOutput.isEmpty {
                            DisclosureGroup("自检详情", isExpanded: $showDetails) {
                                Text(checkOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(8)
                }
                GroupBox("常见问题") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("提示「no such file or directory」？").fontWeight(.medium)
                        Text("通常是快捷指令仍引用已经移动的源码目录。重新复制本页命令并替换旧命令即可。命令使用 App 内置脚本，归档源码不会影响它；移动或重命名 App 后，需要重新复制命令。")
                        Text("复制命令会替换剪贴板。完成设置后，请重新复制要投递的文字。剪贴板为空时会取消投递。")
                        Text("快捷投递默认跟随主窗口的共用排版；开启「使用独立排版」后，可在本页单独调整。")
                        Text("Ctrl+1 自动取内容自带标题、Markdown 标题或第一句正文作为文件名，并附加时间。App 主窗口仍使用手动标题。设备已有同名文件时另存新文件，避免覆盖手写批注。")
                        Text("直连失败时保留本地 PDF，通知中显示路径；重新投递前可先检查设备，避免重复发送。")
                    }.font(.callout).padding(8)
                }
            }.padding(24).frame(maxWidth: 800)
        }.frame(width: embedded ? nil : 640, height: embedded ? nil : 710)
    }

    private func step(_ number: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor private func runCheck() {
        guard let scriptURL else { return }
        checking = true
        checkPassed = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [scriptURL.path, "--check"]
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
            showDetails = !result.0
            checking = false
        }
    }
}

struct FinderQuickActionSettings: View {
    var body: some View {
        GroupBox("Finder 右键投递") {
            VStack(alignment: .leading, spacing: 10) {
                Text("在 Finder 中右键 PDF、Markdown 或 TXT 文件，选择菜单底部的「发送到 QUADERNO」。PDF 原样上传；Markdown 和 TXT 按 Ctrl+1 排版渲染，文件名沿用原文件名。可多选。")
                Text("由本 App 直接提供，无需安装。菜单项未出现时，请在「系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹」中勾选「发送到 QUADERNO」。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}
