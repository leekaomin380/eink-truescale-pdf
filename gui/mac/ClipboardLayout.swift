import SwiftUI
import AppKit
import CoreText

struct ClipboardLayoutProfile: Codable, Equatable {
    var cjkFont = "Songti SC"
    var latinFont = "Times New Roman"
    var bodySize = "10.5pt"
    var margin = "14mm"
    var leading = "0.85em"
    var pageW = "157.1mm"
    var pageH = "209.5mm"
    var docLang = "zh"
    var printTime = true
    var deviceIndex = 0
    var fontFiles: [String] = []

    func withFontFiles() -> Self {
        var result = self
        var paths = Set<String>()
        for name in [latinFont, cjkFont] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let variants: [CTFontSymbolicTraits] = [[], .traitBold, .traitItalic, [.traitBold, .traitItalic]]
            for traits in variants {
                let variant = CTFontCreateCopyWithSymbolicTraits(font, 12, nil, traits, traits) ?? font
                if let url = CTFontCopyAttribute(variant, kCTFontURLAttribute) as? URL {
                    paths.insert(url.path)
                }
            }
        }
        result.fontFiles = paths.sorted()
        return result
    }
}

final class ClipboardLayoutStore: ObservableObject {
    static let shared = ClipboardLayoutStore()
    @Published private(set) var useShared = true
    @Published private(set) var sharedProfile = ClipboardLayoutProfile()
    @Published var independent = ClipboardLayoutProfile()
    @Published private(set) var errorMessage = ""
    @Published private(set) var cjkFonts = ["Songti SC"]
    @Published private(set) var latinFonts = ["Times New Roman"]
    @Published private(set) var devices: [DeviceInfo] = []
    private var hasIndependent = false
    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quaderno Converter/clipboard-layout.json")

    private struct Saved: Codable {
        var version = 1
        var useShared: Bool
        var shared: ClipboardLayoutProfile
        var independent: ClipboardLayoutProfile
        var hasIndependent: Bool
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            useShared = saved.useShared
            sharedProfile = saved.shared
            independent = saved.independent
            hasIndependent = saved.hasIndependent
        }
    }

    var effective: ClipboardLayoutProfile { useShared ? sharedProfile : independent }

    func updateShared(_ profile: ClipboardLayoutProfile, cjk: [String], latin: [String], devices: [DeviceInfo]) {
        sharedProfile = profile
        cjkFonts = Array(Set(cjk + [profile.cjkFont, independent.cjkFont])).sorted()
        latinFonts = Array(Set(latin + [profile.latinFont, independent.latinFont])).sorted()
        self.devices = devices
        persist()
    }

    func setIndependent(_ enabled: Bool) {
        if enabled && !hasIndependent {
            independent = sharedProfile
            hasIndependent = true
        }
        useShared = !enabled
        persist()
    }

    func copyShared() {
        independent = sharedProfile
        hasIndependent = true
        persist()
    }

    func selectIndependentDevice(_ index: Int) {
        guard devices.indices.contains(index) else { return }
        let device = devices[index]
        independent.deviceIndex = index
        independent.pageW = String(format: "%.1fmm", device.displayMm[0])
        independent.pageH = String(format: "%.1fmm", device.displayMm[1])
        persist()
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = Saved(useShared: useShared, shared: sharedProfile.withFontFiles(),
                              independent: independent.withFontFiles(), hasIndependent: hasIndependent)
            let data = try JSONEncoder().encode(saved)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            errorMessage = ""
        } catch {
            errorMessage = L("快捷投递排版保存失败：\(error.localizedDescription)")
        }
    }
}

struct ClipboardLayoutSettings: View {
    @ObservedObject private var store = ClipboardLayoutStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("跟随主窗口排版")
                    Text(store.useShared ? L("与「文件、文本、网页」共用设置") : L("仅影响 ⌃1 与 Finder 右键投递"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("跟随主窗口排版", isOn: Binding(get: { store.useShared }, set: { store.setIndependent(!$0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(12)
            Divider().padding(.leading, 12)
            VStack(alignment: .leading, spacing: 12) {
                chips
                if !store.useShared {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("目标设备")
                            Picker("目标设备", selection: Binding(get: { store.independent.deviceIndex }, set: { store.selectIndependentDevice($0) })) {
                                ForEach(store.devices.indices, id: \.self) { index in
                                    Text(store.devices[index].name).tag(index)
                                }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("正文字号")
                            Picker("正文字号", selection: $store.independent.bodySize) {
                                ForEach(ConversionViewModel.bodySizeChoices, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("行距")
                            Picker("行距", selection: $store.independent.leading) {
                                ForEach(ConversionViewModel.leadingChoices, id: \.0) { Text($0.1).tag($0.0) }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("页边距")
                            Picker("页边距", selection: $store.independent.margin) {
                                ForEach(ConversionViewModel.marginChoices, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("中文字体")
                            Picker("中文字体", selection: $store.independent.cjkFont) {
                                ForEach(store.cjkFonts, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("西文字体")
                            Picker("西文字体", selection: $store.independent.latinFont) {
                                ForEach(store.latinFonts, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        }
                        GridRow {
                            Text("页脚时间")
                            Toggle("显示时间", isOn: $store.independent.printTime)
                        }
                    }
                    Button("从共用设置重新复制") { store.copyShared() }
                }
                if !store.errorMessage.isEmpty { Text(store.errorMessage).foregroundStyle(.red).font(.caption) }
            }
            .padding(12)
        }
        .onChange(of: store.independent) { _, _ in store.persist() }
    }

    private var chips: some View {
        let profile = store.effective
        let device = store.devices.indices.contains(profile.deviceIndex) ? store.devices[profile.deviceIndex].name : nil
        let leading = ConversionViewModel.leadingChoices.first { $0.0 == profile.leading }.map { L("行距 \($0.1)") }
        let items = [device, profile.bodySize, leading, L("边距 \(profile.margin)"),
                     profile.cjkFont + " / " + profile.latinFont].compactMap { $0 }
        return FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(verbatim: item).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// 换行排列的标签行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if extra > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
