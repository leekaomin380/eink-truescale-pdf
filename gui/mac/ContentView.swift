import SwiftUI
import UniformTypeIdentifiers

enum InputMode: String, CaseIterable {
    case epub = "电子书转换"
    case text = "粘贴文本"
    case wechat = "公众号链接"
}

struct ContentView: View {
    @StateObject private var vm = ConversionViewModel()
    @State private var inputMode: InputMode = .epub
    @State private var isDragOver = false
    @State private var previewImage: NSImage?
    @State private var showFilePicker = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 310, maxWidth: 340)
            previewArea
        }
        .onChange(of: vm.currentPage) { _, _ in
            updatePreview()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Tab bar
                Picker("", selection: $inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: inputMode) { _, _ in
                    vm.sourceFileURL = nil
                    vm.sourceFileName = ""
                    vm.pasteText = ""
                    vm.pasteTitle = ""
                    vm.wechatURL = ""
                    vm.currentPdfURL = nil
                    vm.totalPages = 0
                    vm.renderMetrics = nil
                }

                if inputMode == .epub { epubSection }
                else if inputMode == .text { textSection }
                else { wechatSection }

                Divider()

                deviceSection
                fontSection
                layoutSection

                Divider()

                actionButtons
                statusBar
            }
            .padding(16)
        }
    }

    private var epubSection: some View {
        Group {
            Button(action: { showFilePicker = true }) {
                VStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 24))
                        .foregroundColor(isDragOver ? .accentColor : .secondary)
                    Text(isDragOver ? "松开载入" : "拖入电子书或点击选择")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("EPUB / FB2 / HTML / MD")
                        .font(.caption)
                        .foregroundColor(.gray.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDragOver ? Color.accentColor : Color.secondary.opacity(0.3),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                )
            }
            .buttonStyle(.plain)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "epub")!,
                    UTType(filenameExtension: "fb2")!,
                    UTType(filenameExtension: "html")!,
                    UTType(filenameExtension: "md")!,
                    UTType(filenameExtension: "markdown")!
                ],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    vm.sourceFileURL = url
                    vm.sourceFileName = url.lastPathComponent
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
                    Spacer()
                    Button(action: {
                        vm.sourceFileURL = nil
                        vm.sourceFileName = ""
                        vm.currentPdfURL = nil
                        vm.totalPages = 0
                        vm.renderMetrics = nil
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
        Group {
            Label("标题", systemImage: "text.quote")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("可选，留空自动提取 # 标题", text: $vm.pasteTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $vm.pasteText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.visible)
                .border(Color.secondary.opacity(0.2), width: 1)
                .frame(minHeight: 140)
        }
    }

    private var wechatSection: some View {
        Group {
            Label("公众号文章链接", systemImage: "link")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("粘贴 mp.weixin.qq.com/s/...", text: $vm.wechatURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !vm.wechatURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.convertWechat()
                    }
                }

            Button(action: { vm.convertWechat() }) {
                HStack {
                    if vm.isConverting {
                        ProgressView().controlSize(.small)
                    }
                    Text("解析并预览")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isConverting || vm.wechatURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var deviceSection: some View {
        Group {
            Label("目标设备", systemImage: "device.phone")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $vm.selectedDeviceIndex) {
                ForEach(0..<vm.devices.count, id: \.self) { i in
                    Text(vm.devices[i].name).tag(i)
                }
            }
            .pickerStyle(.menu)

            if let dev = vm.selectedDevice {
                HStack(spacing: 6) {
                    Text(dev.sizeVerified ? "✓ 已实测" : "⚠ 未实测")
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
        Group {
            Label("中文字体", systemImage: "textformat.abc")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $vm.selectedCjkFont) {
                ForEach(vm.cjkFonts, id: \.self) { f in
                    Text(f).tag(f)
                }
            }
            .pickerStyle(.menu)

            Label("西文字体", systemImage: "textformat")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $vm.selectedLatinFont) {
                ForEach(vm.latinFonts, id: \.self) { f in
                    Text(f).tag(f)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var layoutSection: some View {
        Group {
            Label("正文字号", systemImage: "textformat.size")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $vm.bodySize) {
                ForEach(["9pt", "10pt", "10.5pt", "11pt", "11.5pt", "12pt", "13pt", "14pt"], id: \.self) { s in
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
            }

            HStack {
                VStack(alignment: .leading) {
                    Label("页边距", systemImage: "rectangle.dashed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $vm.margin) {
                        ForEach(["8mm", "10mm", "12mm", "14mm", "16mm"], id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                }
                VStack(alignment: .leading) {
                    Label("行距", systemImage: "arrow.up.and.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $vm.leading) {
                        ForEach(["0.7em", "0.8em", "0.85em", "0.9em", "1.0em"], id: \.self) { l in
                            Text(l).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Label("语言", systemImage: "globe")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $vm.docLang) {
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
        }
    }

    private var actionButtons: some View {
        Group {
            Button(action: {
                switch inputMode {
                case .epub: vm.convertEpub()
                case .text: vm.convertText()
                case .wechat: vm.convertWechat()
                }
            }) {
                HStack {
                    if vm.isConverting {
                        ProgressView().controlSize(.small)
                    }
                    Text(inputMode == .wechat ? "解析并预览" : "预览")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isConverting || (inputMode == .epub && vm.sourceFileURL == nil)
                      || (inputMode == .text && vm.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                      || (inputMode == .wechat && vm.wechatURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .keyboardShortcut(.return, modifiers: .command)

            if vm.hasQuaderno {
                Button(action: { vm.deliverToDevice() }) {
                    Text("发送到 Quaderno")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.currentPdfURL == nil)
            }

            Button(action: { vm.savePDF() }) {
                Text("另存 PDF…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.currentPdfURL == nil)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var statusBar: some View {
        Group {
            if !vm.statusMessage.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundColor(statusColor)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private var statusColor: Color {
        switch vm.statusKind {
        case .ok: return .green
        case .err: return .red
        case .run: return .orange
        case .info: return .secondary
        }
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        VStack(spacing: 0) {
            // Page bar
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

                Spacer()

                if let m = vm.renderMetrics {
                    if m.sizeUniform {
                        Label("页面尺寸统一", systemImage: "checkmark.seal")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else {
                        Label("尺寸不一致", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Preview
            GeometryReader { geo in
                if let img = previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geo.size.width - 40, maxHeight: geo.size.height - 20)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 40))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("转换后在此显示预览")
                            .foregroundColor(.secondary)
                        Text("按页面真实宽高比呈现")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))

            // Bottom info bar
            HStack(spacing: 16) {
                if let dev = vm.selectedDevice {
                    Text("页面 \(vm.config.pageW) × \(vm.config.pageH)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let m = vm.renderMetrics {
                    Text("版心 \(String(format: "%.1f", m.measureMm))mm")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("字号 \(vm.bodySize)")
                        .font(.caption2).foregroundColor(.secondary)
                    if m.pages > 0 {
                        Text("共 \(m.pages) 页")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onChange(of: vm.currentPdfURL) { _, _ in updatePreview() }
    }

    // MARK: - Actions

    private func updatePreview() {
        guard let img = vm.renderPage(vm.currentPage) else {
            previewImage = nil
            return
        }
        previewImage = img
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                vm.sourceFileURL = url
                vm.sourceFileName = url.lastPathComponent
            }
        }
        return true
    }
}
