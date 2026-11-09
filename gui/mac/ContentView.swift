import SwiftUI
import UniformTypeIdentifiers

enum InputMode: String, CaseIterable {
    case epub = "文件"
    case text = "文本"
    case wechat = "网页"
    case shortcut = "快捷键投递"

    var title: String {
        switch self {
        case .epub: L("文件")
        case .text: L("文本")
        case .wechat: L("网页")
        case .shortcut: L("快捷键投递")
        }
    }
}

/// 按条件切换主/次按钮样式。
/// SwiftUI 的 `.bordered` 与 `.borderedProminent` 是不同类型，无法用三目运算符切换，
/// 只能把分支放进 ViewModifier。
private struct PrimaryStyled: ViewModifier {
    let isPrimary: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isPrimary {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

struct ContentView: View {
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme

    private var sidebarSurface: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(white: 0.965)
    }
    @StateObject private var vm: ConversionViewModel
    @ObservedObject private var navigation = MainNavigation.shared
    @State private var inputMode: InputMode = .epub
    @State private var isDragOver = false
    @State private var previewImage: NSImage?
    @State private var previewRevision = 0
    @State private var lastPreviewKey: String?
    @State private var showFilePicker = false
    @State private var clearedPasteText: String?
    @State private var clearedWechatURL: String?
    @State private var showClearNotice = false
    @State private var clearNoticeID = UUID()
    private enum LayoutHint { case margin, footer }
    @State private var layoutHint: LayoutHint?
    @State private var layoutHintTask: Task<Void, Never>?
    @AppStorage("isAdvancedExpanded") private var isAdvancedExpanded = false
    init(viewModel: ConversionViewModel = ConversionViewModel(), initialMode: InputMode = .epub) {
        _vm = StateObject(wrappedValue: viewModel)
        _inputMode = State(initialValue: initialMode)
    }

    private let cjkNames: [String: String] = [
        "PingFang SC": L("苹方"), "Songti SC": L("宋体"), "Heiti SC": L("黑体"),
        "STSong": L("华文宋体"), "Hiragino Sans GB": L("冬青黑体"),
        "Noto Sans CJK SC": L("思源黑体"), "Noto Serif CJK SC": L("思源宋体"),
        "LXGW Neo ZhiSong": L("霞鹜新致宋"), "Kaiti SC": L("楷体"),
        "STFangsong": L("华文仿宋"), "Source Han Sans SC": L("思源黑体"),
        "Source Han Serif SC": L("思源宋体")
    ]

    private func cjkDisplayName(for name: String) -> String {
        if let cn = cjkNames[name] {
            return cn
        }
        return name
    }

    /// 当前模式下是否已有可渲染的输入。
    /// 发送/另存不再要求「必须先预览」—— 它们会在内容脱节时自行重渲（见 vm.ensureFresh），
    /// 故按钮条件与「预览」一致：有输入即可点。
    private var hasInput: Bool {
        switch inputMode {
        case .epub:   return vm.sourceFileURL != nil
        case .text:   return !vm.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .wechat: return !vm.wechatURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .shortcut: return false
        }
    }

    /// 标题栏显示当前文档，而非固定的应用名 —— macOS 惯例，
    /// 也让同时开多个窗口时能一眼分辨。
    private var windowTitle: String {
        switch navigation.page {
        case .settings: return L("设置")
        case .about: return L("关于 TrueScale for QUADERNO")
        case .files: return L("设备文件")
        case nil: break
        }
        switch inputMode {
        case .epub:
            return vm.sourceFileName.isEmpty ? L("电子书转换") : vm.sourceFileName
        case .text:
            let t = vm.pasteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? L("粘贴文本") : t
        case .wechat:
            return vm.wechatURL.isEmpty ? L("网页链接") : vm.wechatURL
        case .shortcut:
            return L("快捷键投递")
        }
    }

    private func showLayoutHint(_ hint: LayoutHint) {
        layoutHintTask?.cancel()
        withAnimation(AppMotion.expand) { layoutHint = hint }
        layoutHintTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.exit) { layoutHint = nil }
        }
    }

    @ViewBuilder
    private var layoutHintOverlay: some View {
        if let hint = layoutHint {
            GeometryReader { geometry in
                let pageWidth = Double(vm.config.pageW.replacingOccurrences(of: "mm", with: "")) ?? 157.1
                let pageHeight = Double(vm.config.pageH.replacingOccurrences(of: "mm", with: "")) ?? 209.5
                let margin = Double(vm.margin.replacingOccurrences(of: "mm", with: "")) ?? 10
                let insetX = geometry.size.width * margin / pageWidth
                let insetY = geometry.size.height * margin / pageHeight
                ZStack(alignment: .top) {
                    if hint == .margin {
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .padding(.horizontal, insetX)
                            .padding(.vertical, insetY)
                        Text("页边距 \(vm.margin)")
                            .font(.caption)
                            .padding(5)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: geometry.size.width / 2, y: max(insetY, 36))
                    } else {
                        Label(vm.printTime ? L("页脚时间：将显示") : L("页脚时间：将隐藏"), systemImage: "clock")
                            .font(.caption)
                            .padding(6)
                            .background(.regularMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(.horizontal, max(insetX, 8))
                            .padding(.bottom, max(insetY / 2, 6))
                    }
                    Text("设置示意，刷新后生效")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 6)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .allowsHitTesting(false)
            .transition(AppMotion.hintTransition)
        }
    }

    /// 页框尺寸：按目标设备显示区的真实宽高比，等比放进可用空间。
    /// 有无预览都用同一个框 —— 未转换时用户也能看到内容将落在多大的版面里。
    private func pageBox(in available: CGSize) -> CGSize {
        let wmm = Double(vm.config.pageW.replacingOccurrences(of: "mm", with: "")) ?? 157.1
        let hmm = Double(vm.config.pageH.replacingOccurrences(of: "mm", with: "")) ?? 209.5
        guard wmm > 0, hmm > 0 else { return available }
        let maxW = max(available.width - 48, 40)
        let maxH = max(available.height - 32, 40)
        let scale = min(maxW / wmm, maxH / hmm)
        return CGSize(width: wmm * scale, height: hmm * scale)
    }

    var body: some View {
        Group {
            switch navigation.page {
            case .settings:
                AppSettingsView()
            case .about:
                AboutView()
            case .files:
                DeviceFilesPage()
            case nil:
                HSplitView {
                    sidebar
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 520)
                    if inputMode == .shortcut {
                        QuickSendOverview()
                            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        previewArea
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { pageToolbar }
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(isPresented: $navigation.showSetupGuide) { SetupGuideSheet() }
        .onAppear {
            vm.activeKind = switch inputMode {
                case .epub: .epub
                case .text: .text
                case .wechat: .wechat
                case .shortcut: vm.activeKind
            }
            // 首次使用且尚未配对时自动打开设置向导；「以后再说」后不再自动弹出。
            if !Pairing.isPaired && !UserDefaults.standard.bool(forKey: Pairing.guideDismissedKey) {
                navigation.showSetupGuide = true
            }
        }
        .onChange(of: vm.currentPage) { _, _ in
            updatePreview()
        }
        // 排版参数一改就落盘。
        // 【为何逐项监听而不在退出时统一保存】app 是常驻型（关窗不退出），
        // 「退出时保存」在异常退出或强制关闭时会丢；而这些值改动频率极低，
        // 每次写一个 UserDefaults 字典的开销可以忽略。
        .onChange(of: vm.selectedCjkFont)     { _, _ in vm.savePreferences() }
        .onChange(of: vm.selectedLatinFont)   { _, _ in vm.savePreferences() }
        .onChange(of: vm.bodySize)            { _, _ in vm.savePreferences() }
        .onChange(of: vm.margin)              { _, _ in vm.savePreferences(); showLayoutHint(.margin) }
        .onChange(of: vm.printTime) { _, _ in vm.savePreferences(); showLayoutHint(.footer) }
        .onChange(of: vm.leading)             { _, _ in vm.savePreferences() }
        .onChange(of: vm.selectedDeviceIndex) { _, _ in vm.savePreferences() }
        .onChange(of: vm.landscape)           { _, _ in vm.savePreferences() }
        .onChange(of: vm.renderTraditional)   { _, _ in vm.savePreferences() }
        .navigationTitle(windowTitle)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Toolbar: 设置 / 关于

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        if navigation.page != nil {
            ToolbarItem(placement: .navigation) {
                Button("返回", systemImage: "chevron.left") { navigation.page = nil }
                    .help(L("返回输入页"))
            }
        }
        ToolbarItem(placement: .primaryAction) { USBStatusBadge() }
        ToolbarItem(placement: .primaryAction) { RecentDeliveriesButton() }
        ToolbarItem(placement: .primaryAction) { ScreenshotButton() }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { togglePage(.files) } label: {
                Label("设备文件", systemImage: navigation.page == .files ? "folder.fill" : "folder")
            }
            .help(L("设备文件"))
            // Buttons, not Toggles: a toolbar Toggle writes its binding while the toolbar is built.
            Button { togglePage(.settings) } label: {
                Label("设置", systemImage: navigation.page == .settings ? "gearshape.fill" : "gearshape")
            }
            .help(L("设置"))
            Button { togglePage(.about) } label: {
                Label("关于", systemImage: navigation.page == .about ? "info.circle.fill" : "info.circle")
            }
            .help(L("关于 TrueScale for QUADERNO"))
        }
    }

    private func togglePage(_ page: MainPage) {
        navigation.page = navigation.page == page ? nil : page
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            inputModePicker
            Divider()

            if inputMode == .shortcut {
                ScrollView { QuickSendSidebar() }
            } else {
                if inputMode == .text {
                    textWorkspace
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if inputMode == .epub { epubSection }
                            else { wechatSection }
                            Divider()
                            settingsSection
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sidebarSurface)
                    }
                    .background(sidebarSurface)
                }
                Divider()
                sidebarFooter
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
            }
        }
        .background(sidebarSurface)
    }

    private var inputModePicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker("输入来源", selection: $inputMode) {
                ForEach(InputMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)

            Picker("输入来源", selection: $inputMode) {
                ForEach(InputMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(sidebarSurface)
        .onChange(of: inputMode) { _, newMode in
            layoutHintTask?.cancel()
            layoutHint = nil
            showClearNotice = false
            clearedPasteText = nil
            clearedWechatURL = nil

            if newMode == .shortcut {
                return
            }
            vm.activeKind = switch newMode {
                case .epub: .epub
                case .text: .text
                case .wechat: .wechat
                case .shortcut: vm.activeKind
            }

            // 每个来源的草稿各自保留；切换时只移除与当前来源不再对应的预览。
            vm.currentPdfURL = nil
            vm.currentPage = 1
            vm.totalPages = 0
            vm.renderMetrics = nil
            previewImage = nil
        }
    }

    /// Scroll the entire editing/settings area; reserve the footer before allocating space.
    /// The native editor scrolls its own text, while the outer scroll keeps every setting reachable.
    private var textWorkspace: some View {
        GeometryReader { available in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    textSection
                        .frame(height: max(260, min(440, available.size.height * 0.65)))
                    Divider()
                    settingsSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sidebarSurface)
            }
            .background(sidebarSurface)
            .scrollIndicators(.visible)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("排版设置", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))

            pageFormatSection
            layoutSummary

            layoutBasicSection

            VStack(alignment: .leading, spacing: 8) {
                settingHeading("中文输出", symbol: "character.book.closed")
                Picker("中文输出", selection: $vm.renderTraditional) {
                    Text("保持原文").tag(false)
                    Text("繁体中文").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            DisclosureGroup("进阶设置", isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    fontSection
                    layoutAdvancedSection
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
            .animation(AppMotion.expand, value: isAdvancedExpanded)
        }
    }

    private var epubSection: some View {
        Group {
            // 已选文件后收起投放区：左栏是本 app 最紧张的空间，
            // 让一个已经完成的操作继续占着约 130pt 的空态是纯浪费。
            // 收起后仍是完整的投放目标与选择入口，只是不再喧宾夺主。
            Button(action: { showFilePicker = true }) {
                Group {
                    if vm.sourceFileName.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 24))
                                .foregroundColor(isDragOver ? .accentColor : .secondary)
                            Text(isDragOver ? L("松开载入") : L("拖入文件或点击选择"))
                                .font(.callout)
                                .foregroundColor(.secondary)
                            Text("EPUB / HTML / FB2 / Markdown")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.badge.plus")
                                .font(.caption)
                                .foregroundColor(isDragOver ? .accentColor : .secondary)
                            Text(isDragOver ? L("松开载入") : L("更换文件"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDragOver ? Color.accentColor : Color.secondary.opacity(0.3),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                )
            }
            .buttonStyle(.plain)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: SupportedFileFormat.allowedExtensions.compactMap { UTType(filenameExtension: $0) },
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    _ = vm.selectSourceFile(url: url)
                }
            }

            if !vm.sourceFileName.isEmpty {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    Text(vm.sourceFileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let typeName = vm.sourceFileTypeDisplayName {
                        Text(typeName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        vm.clearSourceFile()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
            }
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("标题", systemImage: "text.quote")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("可选，留空自动提取 # 标题", text: $vm.pasteTitle)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Text("正文")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("支持 Markdown")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))

                Spacer()

                Button("清空正文", action: clearPasteText)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundColor(.secondary)
                    .disabled(vm.pasteText.isEmpty)
                    .help("清除正文并保留标题，可撤销")
            }

            MarkdownPasteEditor(text: $vm.pasteText)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .frame(minHeight: 180, maxHeight: .infinity)
                .onChange(of: vm.pasteText) { _, newValue in
                    // 清空后开始新的输入，旧内容不再适合作为快捷“撤销”目标。
                    if showClearNotice && !newValue.isEmpty {
                        showClearNotice = false
                        clearedPasteText = nil
                    }
                }
        }
    }

    private var wechatSection: some View {
        Group {
            HStack(spacing: 8) {
                Label("网页文章链接", systemImage: "link")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("清空链接", action: clearWechatURL)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundColor(.secondary)
                    .disabled(vm.wechatURL.isEmpty)
                    .help("清除网页链接，可撤销")
            }
            TextField("粘贴网页链接（公众号 / 博客文章）", text: $vm.wechatURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !vm.wechatURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.convertWechat()
                    }
                }
                .onChange(of: vm.wechatURL) { _, newValue in
                    if showClearNotice && !newValue.isEmpty {
                        showClearNotice = false
                        clearedWechatURL = nil
                    }
                }

            // 主操作按钮统一放在下方按钮组，与其它输入模式一致 ——
            // 此处不再重复一个「解析并预览」。回车仍可直接触发（见上方 onSubmit）。
        }
    }

    private func settingHeading(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label { Text(title) } icon: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 16)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.monochrome)
    }

    private var pageFormatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingHeading("页面规格", symbol: "doc")
            Picker("页面规格", selection: $vm.pagePresetID) {
                Section("设备屏幕") { Text("QUADERNO").tag("device") }
                Section("标准纸张") {
                    ForEach(StandardPaper.all) { paper in Text(paper.name).tag(paper.id) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            if vm.isStandardPaper {
                settingHeading("页面方向", symbol: "arrow.triangle.2.circlepath")
                Picker("页面方向", selection: $vm.landscape) {
                    Label("纵向", systemImage: "rectangle.portrait").tag(false)
                    Label("横向", systemImage: "rectangle").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } else {
                deviceSection
            }
        }
    }

    private var deviceSection: some View {
        Group {
            settingHeading("目标设备", symbol: "rectangle.portrait")
            Picker("", selection: $vm.selectedDeviceIndex) {
                ForEach(0..<vm.devices.count, id: \.self) { i in
                    Text(vm.devices[i].name).tag(i)
                }
            }
            .pickerStyle(.menu)

            if let dev = vm.selectedDevice {
                HStack(spacing: 6) {
                    Text(dev.sizeVerified ? L("✓ 已实测") : L("⚠ 未实测"))
                        .font(.caption2)
                        .foregroundColor(dev.sizeVerified ? .green : .orange)
                    Text("显示区 \(dev.displaySizeLabel)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingHeading("中文字体", symbol: "pencil.tip")
            FontFamilyPicker(
                choices: vm.cjkFonts.map { FontChoice(family: $0, title: cjkDisplayName(for: $0)) },
                accessibilityTitle: L("中文字体"), selection: $vm.selectedCjkFont)
                .frame(maxWidth: .infinity)

            settingHeading("西文字体（英文与数字）", symbol: "pencil.tip")
            FontFamilyPicker(
                choices: vm.latinFonts.map { FontChoice(family: $0, title: $0) },
                accessibilityTitle: L("西文字体（英文与数字）"), selection: $vm.selectedLatinFont)
                .frame(maxWidth: .infinity)

            mixedFontSpecimen
        }
    }

    private var mixedFontSpecimen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("中英混排样张")
                Spacer()
                Text("18pt · 常规")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(FontSpecimenTypography.sample(cjkFamily: vm.selectedCjkFont,
                                                latinFamily: vm.selectedLatinFont,
                                                traditional: vm.renderTraditional))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(Text("中英混排样张"))
        .accessibilityValue(Text(verbatim: "\(vm.selectedCjkFont) / \(vm.selectedLatinFont)"))
    }

    /// 版面摘要：页面物理尺寸、版心宽度、全书尺寸一致性校验。
    ///
    /// 【为何提到这里】这三项正是本产品区别于任意一个 epub 转换器的地方
    /// （见 docs/PRODUCT.md 核心价值第 1、3 条：尺寸可理解、结果可验证），
    /// 此前却是窗口最底的 caption2 灰字，其中校验标记还被截断在右上角。
    /// 用户注意不到，也就无从理解自己为什么该用这个工具。
    private var layoutSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "ruler")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(vm.config.pageW) × \(vm.config.pageH)")
                    .font(.callout.monospacedDigit())
                Text(vm.pagePresetName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let m = vm.renderMetrics {
                HStack(spacing: 8) {
                    Text("版心 \(String(format: "%.1f", m.measureMm))mm")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if m.pages > 0 {
                        Text("共 \(m.pages) 页")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if m.sizeUniform {
                        Label("尺寸统一", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Label("尺寸不一致", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .opacity(vm.isStale ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var layoutBasicSection: some View {
        Group {
            settingHeading("正文字号", symbol: "textformat.size")
            Picker("", selection: $vm.bodySize) {
                ForEach(ConversionViewModel.bodySizeChoices, id: \.self) { s in
                    Text(s).tag(s)
                }
            }
            .pickerStyle(.menu)

            if let m = vm.renderMetrics {
                HStack(spacing: 4) {
                    Text("中文 \(m.cjkPerLine) 字/行")
                        .font(.caption2)
                        .foregroundColor(m.cjkPerLine >= 28 && m.cjkPerLine <= 40 ? .green : .orange)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("西文 \(m.latinPerLine) 字符/行")
                        .font(.caption2)
                        .foregroundColor(m.latinPerLine >= 45 && m.latinPerLine <= 75 ? .green : .orange)
                }
                // These figures describe the last preview until the user refreshes it.
                .opacity(vm.isStale ? 0.4 : 1)
            }

            settingHeading("行距", symbol: "arrow.up.and.down")
            Picker("", selection: $vm.leading) {
                ForEach(ConversionViewModel.leadingChoices, id: \.0) { pair in
                    Text(pair.1).tag(pair.0)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var layoutAdvancedSection: some View {
        Group {
            HStack {
                VStack(alignment: .leading) {
                    settingHeading("页边距", symbol: "rectangle.dashed")
                    Picker("", selection: $vm.margin) {
                        ForEach(ConversionViewModel.marginChoices, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                }
                
                VStack(alignment: .leading) {
                    settingHeading("页脚时间", symbol: "clock")
                    Toggle("开启", isOn: $vm.printTime)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    /// 主操作区。
    ///
    /// 编辑只标记待更新；刷新、投递或另存时才生成 PDF。
    ///
    /// 网页模式例外：它要发起网络抓取，必须由用户显式触发，故保留独立按钮。
    private var actionButtons: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    deliverButton
                    savePDFButton
                }
                VStack(spacing: 8) {
                    deliverButton
                    savePDFButton
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    refreshButton
                    exportMarkdownButton
                }
                VStack(spacing: 8) {
                    refreshButton
                    exportMarkdownButton
                }
            }
        }
    }

    private var refreshButton: some View {
        Button(action: {
            if inputMode == .wechat { vm.convertWechat() }
            else { vm.ensureFresh {} }
        }) {
            Label(inputMode == .wechat ? L("解析并预览") : L("刷新预览"),
                  systemImage: inputMode == .wechat ? "doc.text.magnifyingglass" : "arrow.clockwise")
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .foregroundStyle(Color.primary.opacity(0.72))
        .disabled(vm.isConverting || vm.isDelivering || !hasInput)
        .keyboardShortcut("r", modifiers: .command)
    }

    private var exportMarkdownButton: some View {
        Button(action: { vm.exportMarkdown() }) {
            Label("导出 Markdown…", systemImage: "doc.text")
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .foregroundStyle(Color.primary.opacity(0.72))
        .disabled(vm.isConverting || vm.isDelivering || !hasInput)
        .help(inputMode == .wechat ? L("直接保存 .md，保留正文、原文地址与图片链接，供 AI 阅读") : L("导出为 Markdown（含图片），供 AI 阅读"))
    }

    @ViewBuilder
    private var deliverButton: some View {
        if vm.hasQuaderno && !vm.isStandardPaper {
            Button(action: { vm.requestDelivery() }) {
                Label("投递到 QUADERNO", systemImage: "paperplane")
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
            }
            .modifier(PrimaryStyled(isPrimary: true))
            .disabled(vm.isConverting || vm.isDelivering || !hasInput)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var savePDFButton: some View {
        Button(action: { vm.ensureFresh { vm.savePDF() } }) {
            Label("另存 PDF…", systemImage: "square.and.arrow.down")
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .modifier(PrimaryStyled(isPrimary: !vm.hasQuaderno || vm.isStandardPaper))
        .disabled(vm.isConverting || vm.isDelivering || !hasInput)
        .keyboardShortcut("s", modifiers: .command)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.isDelivering, let progress = vm.deliveryProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if progress.fraction == nil { ProgressView().controlSize(.small) }
                        Text(progress.title)
                            .contentTransition(.opacity)
                            .animation(AppMotion.micro, value: progress.phase)
                        Spacer(minLength: 0)
                        if let fraction = progress.fraction {
                            Text("\(Int(fraction * 100))%")
                                .monospacedDigit()
                                .transaction { $0.animation = nil }
                        }
                    }
                    .font(.caption)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                            .transaction { $0.animation = nil }
                    }
                    if let completed = progress.completed, let total = progress.total, total > 0 {
                        Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if showClearNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(inputMode == .wechat ? L("链接已清空") : L("正文已清空"))
                        .font(.caption)
                    Spacer()
                    Button("撤销") {
                        if inputMode == .wechat {
                            restoreClearedWechatURL()
                        } else {
                            restoreClearedPasteText()
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(6)
            } else {
                statusBar
            }

            actionButtons
        }
        .padding(16)
        .background(sidebarSurface)
        .animation(AppMotion.expand, value: vm.isDelivering)
        .animation(showClearNotice ? AppMotion.expand : AppMotion.exit, value: showClearNotice)
        .imageScale(.medium)
        .symbolRenderingMode(.monochrome)
    }

    private var statusBar: some View {
        Group {
            if !vm.statusMessage.isEmpty || previewPending {
                HStack(spacing: 6) {
                    // 渲染进度原先寄生在「预览」按钮里，按钮删掉后迁到状态条。
                    if vm.isConverting {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 7, height: 7)
                    } else {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(previewPending
                         ? (vm.isStandardPaper ? L("预览待更新，点击刷新预览或另存 PDF") : L("预览待更新，点击刷新预览或直接投递"))
                         : vm.statusMessage)
                        .contentTransition(.opacity)
                        .animation(AppMotion.micro, value: vm.statusMessage)
                        .font(.caption)
                        .foregroundColor(statusColor)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var previewPending: Bool {
        inputMode != .wechat && inputMode != .shortcut && hasInput && vm.isStale
            && !vm.isConverting && !vm.isDelivering && vm.statusKind != .err
    }

    private var statusColor: Color {
        if previewPending { return .secondary }
        switch vm.statusKind {
        case .ok: return .green
        case .err: return .red
        case .run: return .orange
        case .info: return .secondary
        }
    }

    private func clearPasteText() {
        guard !vm.pasteText.isEmpty else { return }

        let previousText = vm.pasteText
        clearedPasteText = previousText
        undoManager?.registerUndo(withTarget: vm) { target in
            target.pasteText = previousText
        }
        undoManager?.setActionName(L("清空正文"))

        vm.pasteText = ""
        vm.currentPdfURL = nil
        vm.currentPage = 1
        vm.totalPages = 0
        vm.renderMetrics = nil
        previewImage = nil

        let noticeID = UUID()
        clearNoticeID = noticeID
        showClearNotice = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard clearNoticeID == noticeID else { return }
            showClearNotice = false
            clearedPasteText = nil
        }
    }

    private func restoreClearedPasteText() {
        guard let text = clearedPasteText else { return }
        vm.pasteText = text
        clearedPasteText = nil
        showClearNotice = false
    }

    private func clearWechatURL() {
        guard !vm.wechatURL.isEmpty else { return }

        let previousURL = vm.wechatURL
        clearedWechatURL = previousURL
        undoManager?.registerUndo(withTarget: vm) { target in
            target.wechatURL = previousURL
        }
        undoManager?.setActionName(L("清空链接"))

        vm.wechatURL = ""
        vm.currentPdfURL = nil
        vm.currentPage = 1
        vm.totalPages = 0
        vm.renderMetrics = nil
        previewImage = nil

        let noticeID = UUID()
        clearNoticeID = noticeID
        showClearNotice = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard clearNoticeID == noticeID else { return }
            showClearNotice = false
            clearedWechatURL = nil
        }
    }

    private func restoreClearedWechatURL() {
        guard let url = clearedWechatURL else { return }
        vm.wechatURL = url
        clearedWechatURL = nil
        showClearNotice = false
    }

    // MARK: - Preview Area

    private var pageNavigation: some View {
        HStack(spacing: 8) {
            Button(action: { vm.currentPage = max(1, vm.currentPage - 1) }) {
                Image(systemName: "chevron.left")
            }
            .disabled(vm.currentPage <= 1)

            Text("第")
            TextField("", value: $vm.currentPage, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .onSubmit { vm.currentPage = max(1, min(vm.totalPages, vm.currentPage)) }
            Text("/ \(vm.totalPages) 页")
                .foregroundColor(.secondary)

            Button(action: { vm.currentPage = min(vm.totalPages, vm.currentPage + 1) }) {
                Image(systemName: "chevron.right")
            }
            .disabled(vm.currentPage >= vm.totalPages)

        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var pageStatusBadge: some View {
        if let m = vm.renderMetrics {
            Group {
                if m.sizeUniform {
                    Label("页面尺寸统一", systemImage: "checkmark.seal")
                        .foregroundColor(.green)
                } else {
                    Label("尺寸不一致", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .opacity(vm.isStale ? 0.4 : 1)
        }
    }


    private var previewArea: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pageNavigation
                    Spacer(minLength: 0)
                    pageStatusBadge
                }
                VStack(alignment: .leading, spacing: 6) {
                    pageNavigation
                    pageStatusBadge
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Preview —— 页框始终按目标设备的真实宽高比呈现，
            // 未转换时同样显示该幅面，让用户先看到「内容会落在多大的版面里」。
            GeometryReader { geo in
                let box = pageBox(in: geo.size)
                ZStack {
                    if let img = previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: box.width, height: box.height)
                            .id(previewRevision)
                            .transition(.opacity)
                    } else {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: box.width, height: box.height)
                            .overlay(
                                Text("准备就绪")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            )
                    }
                }
                .frame(width: box.width, height: box.height)
                .overlay { layoutHintOverlay }
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            // Bottom info bar
            //
            // 【为何去掉「字号」与「共 N 页」】原先这一行混用两个时效的数据源：
            // 「页面」「字号」取自当前设置，「版心」「共 N 页」取自上一次渲染的
            // renderMetrics。改了字号不重渲时会显示「字号 13pt · 共 49 页」，
            // 而 49 页是 10.5pt 的结果 —— 同一行内自相矛盾。
            // 且「字号」与左栏控件、「共 N 页」与上方翻页条本就重复。
            // 现在只保留两项事实性数据，且同属一个时效。
            HStack(spacing: 16) {
                if vm.selectedDevice != nil || vm.isStandardPaper {
                    Text("页面 \(vm.config.pageW) × \(vm.config.pageH)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let m = vm.renderMetrics {
                    Text("版心 \(String(format: "%.1f", m.measureMm))mm")
                        .font(.caption2).foregroundColor(.secondary)
                        .opacity(vm.isStale ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        // 观察世代号而非 currentPdfURL —— 后者在只改排版参数时不会变化
        // （输出路径是确定性的），会导致预览停留在上一次渲染。
        .onChange(of: vm.renderGeneration) { _, _ in updatePreview() }
    }

    // MARK: - Actions

    private func updatePreview() {
        let key = "\(vm.currentPdfURL?.path ?? "")|\(vm.currentPage)|\(vm.renderGeneration)"
        guard key != lastPreviewKey else { return }
        guard let img = vm.renderPage(vm.currentPage) else {
            previewImage = nil
            lastPreviewKey = nil
            return
        }
        lastPreviewKey = key
        withAnimation(AppMotion.micro) {
            previewImage = img
            previewRevision += 1
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                _ = vm.selectSourceFile(url: url)
            }
        }
        return true
    }
}
