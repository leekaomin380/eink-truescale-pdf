import SwiftUI
import AppKit

struct AboutMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("关于 Quaderno Converter") { openWindow(id: "about") }
    }
}

/// 「关于」窗口：项目、作者、许可，以及随 App 分发的第三方组件。
/// 组件清单须与仓库根目录 THIRD-PARTY-LICENSES.md 保持一致。
struct AboutView: View {
    private struct Component: Identifiable {
        let name: String
        let version: String
        let license: String
        let role: String
        let url: String
        var id: String { name }
    }

    private let repository = URL(string: "https://github.com/leekaomin380/eink-truescale-pdf")!

    private var bundled: [Component] {
        [
            Component(name: "pandoc", version: "3.10", license: "GPL-2.0-or-later",
                      role: L("文档格式转换"), url: "https://github.com/jgm/pandoc"),
            Component(name: "Typst", version: "0.15.1", license: "Apache-2.0",
                      role: L("PDF 排版引擎"), url: "https://github.com/typst/typst"),
            Component(name: "GNU MP", version: "6.x", license: "LGPL-3.0-or-later / GPL-2.0-or-later",
                      role: L("pandoc 的运行库"), url: "https://gmplib.org/"),
            Component(name: "CPython", version: "3.13", license: "PSF-2.0",
                      role: L("设备直连工具的运行时"), url: "https://www.python.org/"),
            Component(name: "PyCryptodome", version: "3.24.1", license: "BSD-2-Clause / Public Domain",
                      role: L("设备认证签名"), url: "https://www.pycryptodome.org/"),
            Component(name: "PyYAML", version: "6.0.3", license: "MIT",
                      role: L("Markdown 元数据解析"), url: "https://pyyaml.org/"),
            Component(name: "PyInstaller", version: L("引导程序"), license: L("GPL-2.0，含引导程序例外"),
                      role: L("打包设备直连工具"), url: "https://pyinstaller.org/"),
        ]
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Quaderno Converter").font(.title.bold())
                        Text("版本 \(version)").foregroundStyle(.secondary)
                        Text(verbatim: "© 2026 高明 (Gaoming Li) · MIT License").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("按电子纸屏幕的真实物理尺寸排版文字、网页与电子书，并直接投递到 FUJITSU QUADERNO。由一位 QUADERNO 用户为自己的阅读习惯开发，以开源方式发布。")
                HStack {
                    Link(destination: repository) { Label("源代码（GitHub）", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: repository.appendingPathComponent("issues")) { Label("问题反馈", systemImage: "exclamationmark.bubble") }
                }

                GroupBox("随 App 分发的组件") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(bundled) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Link(destination: URL(string: item.url)!) {
                                        Text(verbatim: item.name + " " + item.version).fontWeight(.medium)
                                    }
                                    Text(verbatim: item.role).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(verbatim: item.license).font(.caption.monospaced()).multilineTextAlignment(.trailing)
                            }
                            Divider()
                        }
                        Text("这些组件作为独立程序随 App 分发，由 App 启动调用，各自许可不受本项目 MIT 许可影响。pandoc 仅改写了动态库加载路径并重新签名，未修改源代码。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("在 Finder 中显示许可全文", systemImage: "doc.text.magnifyingglass") { revealLicenses() }
                            .disabled(licensesURL == nil)
                    }.padding(8)
                }

                GroupBox("参考与可选组件") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Link(destination: URL(string: "https://github.com/janten/dpt-rp1-py")!) { Text(verbatim: "dpt-rp1-py") }
                            Text("设备通信协议参考（MIT）。未打包或调用其代码。").font(.callout)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Link(destination: URL(string: "https://calibre-ebook.com/")!) { Text(verbatim: "Calibre") }
                            Text("可选，仅 MOBI / AZW 转换需要（GPL-3.0）。未打包。").font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                Text("FUJITSU 与 QUADERNO 是其各自权利人的商标。本项目是独立的开源项目，与富士通没有关联，也未获得其认可或赞助。设备直连只读取目录并新增文档，不删除或覆盖设备上的文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(width: 560, height: 640)
    }

    private var licensesURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("licenses")
    }

    private func revealLicenses() {
        guard let licensesURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([licensesURL])
    }
}
