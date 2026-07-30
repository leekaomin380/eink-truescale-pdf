import Foundation
import AppKit
import PDFKit

struct DeviceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let vendor: String
    let models: [String]
    let sizeClass: String
    let resolutionPx: [Int]
    let ppi: Double
    let displayBehavior: String
    let behaviorVerified: Bool
    let displayMm: [Double]
    let sizeVerified: Bool
    let diagonalIn: Double

    var displaySizeLabel: String {
        String(format: "%.1f × %.1f mm", displayMm[0], displayMm[1])
    }
}

struct ConfigDefaults {
    var pageW = "157.1mm"
    var pageH = "209.5mm"
    var margin = "10mm"
    var bodySize = "10pt"
    var leading = "0.85em"
    var docLang = "zh"
    var fonts: [String] = ["Helvetica Neue", "PingFang SC"]
}

struct RenderMetrics {
    var pages = 0
    var pageSizes: [String] = []
    var sizeUniform = true
    var measureMm: Double = 0
    var cjkPerLine = 0
    var latinPerLine = 0
    var cjkVerdict = ""
    var latinVerdict = ""
}

class ConversionViewModel: ObservableObject {
    let repoURL: URL

    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceIndex = 0
    @Published var config = ConfigDefaults()
    @Published var cjkFonts: [String] = []
    @Published var latinFonts: [String] = []
    @Published var selectedCjkFont = "PingFang SC"
    @Published var selectedLatinFont = "Helvetica Neue"
    @Published var bodySize = "10pt"
    @Published var margin = "10mm"
    @Published var leading = "0.85em"
    @Published var docLang = "zh"
    @Published var printTime = true
    @Published var statusMessage = ""
    @Published var statusKind: StatusKind = .info
    @Published var isConverting = false

    @Published var currentPdfURL: URL?
    @Published var totalPages = 0
    @Published var currentPage = 1
    @Published var renderMetrics: RenderMetrics?
    @Published var hasQuaderno = false

    // Text paste mode
    @Published var pasteText = ""
    @Published var pasteTitle = ""

    // Wechat mode
    @Published var wechatURL = ""

    // EPUB mode
    @Published var sourceFileURL: URL?
    @Published var sourceFileName = ""
    @Published var pdfTitle = ""  // derived title for delivery filename

    enum StatusKind { case info, ok, err, run }

    /// 行距选项：(内部 em 值, 界面显示的传统倍行距)。
    /// typst 的 leading 是「行间额外空隙」，人们说的「1.5 倍行距」是「基线距 ÷ 字号」，
    /// 二者差一个字身高。实测换算为线性关系：倍数 = em + 0.7。
    /// 界面只显示右侧，em 不外露 —— 显示 0.85 会让人误以为是 0.85 倍，实际是 1.55 倍。
    /// 字号与页边距的可选值。
    /// 【为何放在这里】原先硬编码在 ContentView 的 ForEach 里，而偏好校验需要
    /// 判断"存下来的值是否仍是合法选项"，两处各写一份必然漂移。故收拢为单一来源。
    static let bodySizeChoices = ["9pt", "10pt", "10.5pt", "11pt", "11.5pt", "12pt", "13pt", "14pt"]
    static let marginChoices   = ["8mm", "10mm", "12mm", "14mm", "16mm"]

    static let leadingChoices: [(String, String)] = [
        ("0.7em",  "1.4 倍"),
        ("0.8em",  "1.5 倍"),
        ("0.85em", "1.55 倍"),
        ("0.9em",  "1.6 倍"),
        ("1.0em",  "1.7 倍"),
    ]

    /// 上次渲染所依据的输入指纹（内容 + 全部排版参数）。
    ///
    /// 【为什么需要它】此前发送/另存的唯一条件是「currentPdfURL != nil」，即
    /// 只要曾渲染过任何东西按钮就一直可用，完全不校验当前输入是否对应那个 PDF。
    /// 后果：贴入新文字后不点预览直接发送，发出去的是【上一篇】—— 真的发错内容。
    ///
    /// 网页版当年用 DIRTY 标记解决过此问题（index.html 至今仍有），
    /// 原生 SwiftUI 重写时整套机制丢失，属回归。
    ///
    /// 现改为「发送/另存自行保证正确」：比对指纹，不一致就先重渲再执行 ——
    /// 这样按钮名义与实际行为一致，用户不必记住「必须先预览」这条前置规则。
    private var renderedFingerprint: String?

    /// 当前输入的指纹。任何影响产物的东西都必须计入。
    private func currentFingerprint(mode: InputKind) -> String {
        let source: String
        switch mode {
        case .epub:   source = sourceFileURL?.path ?? ""
        case .text:   source = pasteTitle + "\u{1}" + pasteText
        case .wechat: source = wechatURL
        }
        return [
            String(describing: mode), source,
            bodySize, margin, leading, docLang,
            selectedLatinFont, selectedCjkFont,
            config.pageW, config.pageH,
            String(printTime)
        ].joined(separator: "\u{1F}")
    }

    /// 输入种类。与 ContentView 的 InputMode 对应，但 ViewModel 不依赖 View 层类型。
    enum InputKind { case epub, text, wechat }

    /// 当前处于哪种输入模式 —— 由 View 在切换时同步过来。
    var activeKind: InputKind = .epub

    /// 产物是否已与当前输入脱节。
    var isStale: Bool {
        currentPdfURL == nil || renderedFingerprint != currentFingerprint(mode: activeKind)
    }

    /// 渲染世代号 —— 每次渲染成功后自增，供 View 触发预览刷新。
    ///
    /// 【为何必须有它】View 原先靠 `currentPdfURL` 与 `currentPage` 的变化来刷新预览。
    /// 但输出路径是【确定性】的（文本模式取 markdown 哈希、EPUB 模式取源文件名），
    /// 只改字体/字号/行距时正文未变，路径与页码都不变 —— SwiftUI 的 onChange 认为
    /// 「没有变化」，于是 updatePreview 从不被调用，预览停留在上一次渲染。
    ///
    /// 后果很坏：磁盘上的 PDF 已按新参数重渲（实测确认嵌入字体已换成
    /// STSongti-SC-Regular），发送到设备的文件是对的，**只有预览在骗人**。
    /// 用户据此判断「字体没生效」，实际生效了 —— 比不生效更容易误导。
    ///
    /// 故不再依赖任何可能巧合相等的状态，改用单调自增的显式信号。
    @Published private(set) var renderGeneration = 0

    /// 记录本次渲染对应的输入 —— 渲染成功后调用。
    /// 三条渲染路径（EPUB / 文本 / 公众号）都在成功时收敛到这里，
    /// 故世代号在此自增可保证「渲染成功」与「预览刷新」严格一一对应。
    func markRendered() {
        renderedFingerprint = currentFingerprint(mode: activeKind)
        renderGeneration += 1
    }

    /// 等待渲染完成的回调。渲染是异步的，ensureFresh 需要在它结束后才继续。
    private var pendingRenderCallbacks: [(Bool) -> Void] = []

    /// 渲染流程结束时统一收敛 —— 成功与失败都必须调用，否则等待者永远悬着。
    private func finishPendingRender(success: Bool) {
        let cbs = pendingRenderCallbacks
        pendingRenderCallbacks = []
        cbs.forEach { $0(success) }
    }

    /// 按当前输入模式触发对应的渲染流程。
    private func renderCurrentInput(_ done: @escaping (Bool) -> Void) {
        pendingRenderCallbacks.append(done)
        switch activeKind {
        case .epub:   convertEpub()
        case .text:   convertText()
        case .wechat: convertWechat()
        }
    }

    /// 确保产物与当前输入一致；若已脱节则重新渲染，完成后执行 next。
    /// 这是「发送/另存自行保证正确」的入口。
    func ensureFresh(then next: @escaping () -> Void) {
        guard isStale else { next(); return }
        setStatus("内容有变，正在重新渲染…", .run)
        renderCurrentInput { ok in
            guard ok else { return }   // 失败时状态已由渲染流程写明
            next()
        }
    }

    var selectedDevice: DeviceInfo? {
        guard selectedDeviceIndex < devices.count else { return nil }
        return devices[selectedDeviceIndex]
    }

    init() {
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("book.sh").path) {
            repoURL = resourceURL
        } else {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("book.sh").path) {
                repoURL = cwd
            } else {
                repoURL = cwd.deletingLastPathComponent()
            }
        }

        // File I/O only — fast, safe on main thread
        loadConfig()
        loadDevices()
        hasQuaderno = FileManager.default.fileExists(
            atPath: "/Applications/QUADERNO PC App.app")

        // Populate font lists with config defaults so pickers are immediately usable
        if !config.fonts.isEmpty { latinFonts = [config.fonts[0]] }
        if config.fonts.count >= 2 { cjkFonts = [config.fonts[1]] }

        // Shell calls block — defer to background to avoid SwiftUI layout crash
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fonts = self.listFontsAsync()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cjkFonts = fonts.cjk
                self.latinFonts = fonts.latin
                self.reconcileSavedFonts()
            }
        }
    }

    // MARK: - Config & Devices

    private func loadConfig() {
        let configPath = repoURL.appendingPathComponent("config.sh")
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return }
        func grab(_ key: String, _ def: String = "") -> String {
            let pattern = #"^"# + key + #"="([^"]*)""#
            guard let range = text.range(of: pattern, options: .regularExpression) else { return def }
            return String(text[range]).replacingOccurrences(of: "\(key)=\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        config.pageW = grab("PAGE_W", "157.1mm")
        config.pageH = grab("PAGE_H", "209.5mm")
        config.margin = grab("PAGE_MARGIN", "10mm")
        config.bodySize = grab("BODY_SIZE", "10pt")
        config.leading = grab("LEADING", "0.85em")
        config.docLang = grab("DOC_LANG", "zh")

        let fontPattern = #"FONTS=\(([^)]*)\)"#
        if let range = text.range(of: fontPattern, options: .regularExpression) {
            let fontStr = String(text[range])
            // 按引号分割会产生字体之间的分隔片段（如 " "）——必须 trim 后再判空，
            // 否则那个空格会被当成一个字体名，导致 Picker 选中一个不存在的项而显示空白。
            config.fonts = fontStr.components(separatedBy: "\"")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "FONTS=(" && $0 != ")" }
        }

        bodySize = config.bodySize
        margin = config.margin
        leading = config.leading
        docLang = config.docLang
        if config.fonts.count >= 2 {
            selectedLatinFont = config.fonts[0]
            selectedCjkFont = config.fonts[1]
        }

        // config.sh 是【出厂默认】；用户调过的值优先。
        // 之前没有任何持久化，字体字号每次启动都被打回默认 —— 而这些参数
        // 恰恰是一次性调好、长期不变的东西，每次重设是纯粹的摩擦。
        applySavedPreferences()
    }

    // MARK: - 偏好持久化

    /// UserDefaults 键。加前缀避免与系统或将来的键冲突。
    private enum PrefKey {
        static let cjkFont   = "pref.cjkFont"
        static let latinFont = "pref.latinFont"
        static let bodySize  = "pref.bodySize"
        static let margin    = "pref.margin"
        static let leading   = "pref.leading"
        static let deviceIdx = "pref.deviceIndex"
    }

    /// 用已保存的偏好覆盖出厂默认值。
    ///
    /// 【为何不直接信任存下来的值】字体可能被卸载、devices.json 可能增删条目、
    /// 选项列表可能变化。存的值若已失效就必须回退到默认，否则 Picker 会选中一个
    /// 不存在的项而显示空白 —— 这个坑本项目踩过一次（FONTS 解析出空字符串，
    /// 导致中文字体下拉整个空掉）。故所有值取用前都要校验。
    private func applySavedPreferences() {
        let d = UserDefaults.standard
        // 字号/边距/行距：只接受仍在选项表里的值
        if let v = d.string(forKey: PrefKey.bodySize),
           Self.bodySizeChoices.contains(v) { bodySize = v }
        if let v = d.string(forKey: PrefKey.margin),
           Self.marginChoices.contains(v) { margin = v }
        if let v = d.string(forKey: PrefKey.leading),
           Self.leadingChoices.contains(where: { $0.0 == v }) { leading = v }
        // 字体：能否使用要等字体列表异步加载完才知道，故此处先存起来，
        // 由 reconcileSavedFonts() 在列表就绪后再校验。
        if let v = d.string(forKey: PrefKey.cjkFont)   { selectedCjkFont = v }
        if let v = d.string(forKey: PrefKey.latinFont) { selectedLatinFont = v }
        // 设备索引：devices 已在 loadDevices 中同步载入，可立即校验
        let idx = d.integer(forKey: PrefKey.deviceIdx)
        if idx > 0 && idx < devices.count { selectedDeviceIndex = idx }
    }

    /// 字体列表异步就绪后，核对已保存的字体是否真的可用；不可用则回退到出厂默认。
    private func reconcileSavedFonts() {
        if !cjkFonts.isEmpty, !cjkFonts.contains(selectedCjkFont) {
            selectedCjkFont = config.fonts.count >= 2 ? config.fonts[1] : cjkFonts[0]
        }
        if !latinFonts.isEmpty, !latinFonts.contains(selectedLatinFont) {
            selectedLatinFont = config.fonts.first ?? latinFonts[0]
        }
    }

    /// 保存当前偏好。由 View 在参数变化时调用。
    func savePreferences() {
        let d = UserDefaults.standard
        d.set(selectedCjkFont,   forKey: PrefKey.cjkFont)
        d.set(selectedLatinFont, forKey: PrefKey.latinFont)
        d.set(bodySize,          forKey: PrefKey.bodySize)
        d.set(margin,            forKey: PrefKey.margin)
        d.set(leading,           forKey: PrefKey.leading)
        d.set(selectedDeviceIndex, forKey: PrefKey.deviceIdx)
    }

    private func loadDevices() {
        let devicesPath = repoURL.appendingPathComponent("devices.json")
        guard let data = try? Data(contentsOf: devicesPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sizeClasses = json["size_classes"] as? [[String: Any]],
              let deviceList = json["devices"] as? [[String: Any]] else { return }

        var classMap: [String: [String: Any]] = [:]
        for sc in sizeClasses {
            if let id = sc["id"] as? String { classMap[id] = sc }
        }

        for d in deviceList {
            guard let sizeClass = d["size_class"] as? String,
                  let sc = classMap[sizeClass] else { continue }
            let displayMm = (sc["display_mm"] as? [Double]) ?? [0, 0]
            let diag = (sc["diagonal_in"] as? Double) ?? 0
            let verified = (sc["verified"] as? Bool) ?? false

            devices.append(DeviceInfo(
                name: d["name"] as? String ?? "",
                vendor: d["vendor"] as? String ?? "",
                models: d["models"] as? [String] ?? [],
                sizeClass: sizeClass,
                resolutionPx: d["resolution_px"] as? [Int] ?? [0, 0],
                ppi: (d["ppi"] as? Double) ?? 0,
                displayBehavior: d["display_behavior"] as? String ?? "unknown",
                behaviorVerified: (d["behavior_verified"] as? Bool) ?? false,
                displayMm: displayMm,
                sizeVerified: verified,
                diagonalIn: diag
            ))
        }
    }

    private func listFontsAsync() -> (cjk: [String], latin: [String]) {
        let result = runShell(["typst", "fonts"])
        guard result.exitCode == 0 else {
            return (
                ["PingFang SC", "Songti SC", "Heiti SC", "Microsoft YaHei", "SimSun"],
                ["Helvetica Neue", "Charter", "Georgia", "Times New Roman", "Calibri"]
            )
        }
        let allFonts = Set(result.stdout.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

        let cjkPref = ["PingFang SC", "Songti SC", "Heiti SC", "STSong",
                        "Hiragino Sans GB", "Noto Serif CJK SC",
                        "Source Han Sans SC", "Source Han Serif SC",
                        "Microsoft YaHei", "SimSun"]
        let latinPref = ["Charter", "Iowan Old Style", "Georgia", "Palatino",
                         "Times New Roman", "Helvetica Neue", "Arial", "Avenir Next",
                         "Calibri"]

        let cjk = cjkPref.filter { allFonts.contains($0) }
        let latin = latinPref.filter { allFonts.contains($0) }
        return (
            cjk.isEmpty ? ["PingFang SC"] : cjk,
            latin.isEmpty ? ["Helvetica Neue"] : latin
        )
    }

    // MARK: - Metrics

    func computeMetrics(pages: Int? = nil, pageSizes: [String]? = nil) -> RenderMetrics {
        let pageWmm = Double(config.pageW.replacingOccurrences(of: "mm", with: "")) ?? 157.1
        let marginMm = Double(margin.replacingOccurrences(of: "mm", with: "")) ?? 10
        let sizePt = Double(bodySize.replacingOccurrences(of: "pt", with: "")) ?? 10
        let measure = pageWmm - 2 * marginMm
        let sizeMm = sizePt * 25.4 / 72
        let cjk = Int(round(measure / sizeMm))
        let lat = Int(round(measure / (sizeMm * 0.5)))

        var m = RenderMetrics()
        m.measureMm = measure
        m.cjkPerLine = cjk
        m.latinPerLine = lat
        m.cjkVerdict = cjk > 45 ? "偏密" : cjk > 40 ? "偏长" : cjk >= 28 ? "合适" : "偏短"
        m.latinVerdict = lat > 75 ? "偏长" : lat >= 45 ? "合适" : "偏短"
        if let p = pages { m.pages = p }
        if let s = pageSizes {
            m.pageSizes = s
            m.sizeUniform = s.count <= 1
        }
        return m
    }

    // MARK: - Convert

    func convertEpub() {
        guard let src = sourceFileURL else {
            setStatus("请先选择文件", .err)
            return
        }
        setStatus("渲染中…", .run)
        isConverting = true

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("p2q_app")
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let outPdf = workDir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".pdf")

            let result = runShell([
                repoURL.appendingPathComponent("book.sh").path,
                src.path, "-o", outPdf.path,
                "--size", bodySize, "--margin", margin,
                "--leading", leading, "--lang", docLang,
                "--font", "\(selectedLatinFont),\(selectedCjkFont)",
                "--page", config.pageW, config.pageH,
                printTime ? "--time" : "--no-time"
            ])

            DispatchQueue.main.async { [self] in
                isConverting = false
                if result.exitCode != 0 {
                    setStatus("渲染失败：\(result.stderr.suffix(200))", .err)
                    self.finishPendingRender(success: false)
                    return
                }
                self.currentPdfURL = outPdf
                let info = PDFDocument(url: outPdf)
                self.totalPages = info?.pageCount ?? 0
                self.currentPage = 1
                let sizes = getPageSizes(pdf: outPdf, pages: self.totalPages)
                self.renderMetrics = computeMetrics(pages: self.totalPages, pageSizes: sizes)
                setStatus("渲染完成，共 \(self.totalPages) 页", .ok)
                self.markRendered()
                self.finishPendingRender(success: true)
            }
        }
    }

    func convertText() {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setStatus("请先粘贴文本", .err)
            return
        }
        setStatus("渲染中…", .run)
        isConverting = true

        var finalText = text
        let title = pasteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && !text.hasPrefix("---") {
            let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            finalText = "---\ntitle: \"\(safeTitle)\"\n---\n\n\(text)"
        }
        renderMarkdown(finalText, title: title)
    }

    func convertWechat() {
        let raw = wechatURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            setStatus("请先粘贴链接", .err)
            return
        }
        guard let url = URL(string: raw),
              let host = url.host?.lowercased(),
              host.contains("mp.weixin.qq.com") else {
            setStatus("目前只支持微信公众号链接（mp.weixin.qq.com）", .err)
            return
        }
        setStatus("抓取网页…", .run)
        isConverting = true

        fetchWechatHTML(url: url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async {
                    self.isConverting = false
                    self.setStatus("抓取失败：\(e.localizedDescription)", .err)
                }
            case .success(let html):
                DispatchQueue.main.async {
                    self.setStatus("抽取正文…", .run)
                    LocalExtraction.run(html: html, url: raw) { [weak self] outcome in
                        guard let self = self else { return }
                        guard let article = outcome.article else {
                            DispatchQueue.main.async {
                                self.isConverting = false
                                let msg: String
                                if outcome.reason.contains("RISK_GRAY") {
                                    msg = "微信要求验证，请稍后再试或在微信中打开一次该文章"
                                } else if outcome.reason.contains("CONTENT_GONE") {
                                    msg = "该文章已被删除或无法查看"
                                } else if outcome.reason.contains("STRUCT_MISSING") || outcome.reason.contains("EXTRACT_EMPTY") {
                                    msg = "未能识别正文结构（可能不是文章页）"
                                } else if outcome.reason == "js_not_bundled" {
                                    msg = "JS 抽取器未打包，请重新构建 app"
                                } else {
                                    msg = "抽取失败：\(outcome.reason)"
                                }
                                self.setStatus(msg, .err)
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            self.setStatus("下载图片…", .run)
                        }
                        let title = article.title
                        let author = article.author
                        DispatchQueue.main.async {
                            if !title.isEmpty { self.pasteTitle = title }
                        }
                        var md = article.markdown
                        if !title.isEmpty && !md.hasPrefix("---") {
                            let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
                            var frontmatter = "---\ntitle: \"\(safeTitle)\"\n"
                            if let author = author, !author.isEmpty {
                                frontmatter += "author: \"\(author.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
                            }
                            frontmatter += "---\n\n"
                            md = frontmatter + md
                        }
                        ImageInliner.inline(markdown: md) { [weak self] finalMd in
                            DispatchQueue.main.async {
                                self?.setStatus("渲染中…", .run)
                            }
                            self?.renderMarkdown(finalMd, title: title)
                        }
                    }
                }
            }
        }
    }

    private func fetchWechatHTML(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "Quaderno", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "未从微信获取到数据"])))
                return
            }
            let htmlString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""
            completion(.success(htmlString))
        }.resume()
    }

    private func renderMarkdown(_ markdown: String, title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("p2q_app")
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let slug = String(markdown.hashValue, radix: 16, uppercase: false).prefix(8)
            let mdFile = workDir.appendingPathComponent("wechat_\(slug).md")
            let outPdf = workDir.appendingPathComponent("wechat_\(slug).pdf")

            try? markdown.write(to: mdFile, atomically: true, encoding: .utf8)

            let result = runShell([
                repoURL.appendingPathComponent("book.sh").path,
                mdFile.path, "-o", outPdf.path,
                "--size", bodySize, "--margin", margin,
                "--leading", leading, "--lang", docLang,
                "--font", "\(selectedLatinFont),\(selectedCjkFont)",
                "--page", config.pageW, config.pageH,
                printTime ? "--time" : "--no-time",
                "--plain"
            ])

            DispatchQueue.main.async { [self] in
                isConverting = false
                if result.exitCode != 0 {
                    setStatus("渲染失败：\(result.stderr.suffix(200))", .err)
                    self.finishPendingRender(success: false)
                    return
                }
                self.currentPdfURL = outPdf
                let info = PDFDocument(url: outPdf)
                self.totalPages = info?.pageCount ?? 0
                self.currentPage = 1
                let sizes = getPageSizes(pdf: outPdf, pages: self.totalPages)
                self.renderMetrics = computeMetrics(pages: self.totalPages, pageSizes: sizes)
                setStatus("渲染完成，共 \(self.totalPages) 页", .ok)
                self.markRendered()
                self.finishPendingRender(success: true)
            }
        }
    }

    // MARK: - Preview

    func renderPage(_ page: Int, dpi: Int = 110) -> NSImage? {
        guard let pdfURL = currentPdfURL,
              let pdfDoc = PDFDocument(url: pdfURL),
              let pdfPage = pdfDoc.page(at: page - 1) else { return nil }

        let scale = CGFloat(dpi) / 72.0
        let rect = pdfPage.bounds(for: .mediaBox)
        let size = NSSize(width: rect.width * scale, height: rect.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .high
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            pdfPage.draw(with: .mediaBox, to: ctx)
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Deliver

    func deliverToDevice() {
        guard let pdfURL = currentPdfURL else {
            setStatus("无可发送的内容", .err)
            return
        }
        setStatus("正在发送到 Quaderno…", .run)

        let app = "/Applications/QUADERNO PC App.app"
        guard FileManager.default.fileExists(atPath: app) else {
            setStatus("未找到 QUADERNO 客户端", .err)
            return
        }

        // Deliver a copy to protect the original (invariant I2)
        // Use title as filename — QUADERNO client displays file name in its list
        let title = pasteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyName: String
        if !title.isEmpty {
            let safe = title.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
            copyName = String(safe.prefix(60)) + ".pdf"
        } else {
            copyName = pdfURL.lastPathComponent
        }
        let copyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2q_deliver")
            .appendingPathComponent(copyName)
        try? FileManager.default.createDirectory(
            at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if FileManager.default.fileExists(atPath: copyURL.path) {
                try FileManager.default.removeItem(at: copyURL)
            }
            try FileManager.default.copyItem(at: pdfURL, to: copyURL)
        } catch {
            setStatus("创建投递副本失败：\(error.localizedDescription)", .err)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gj", "-na", app, "--args", "--print", copyURL.path]
        try? process.run()
        process.waitUntilExit()

        setStatus("已交客户端，稍后同步到设备", .ok)
    }

    func savePDF() {
        guard let pdfURL = currentPdfURL else {
            setStatus("无可保存的内容", .err)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceFileName.isEmpty
            ? "converted.pdf"
            : sourceFileName.replacingOccurrences(of: #"^(.+)\.[^.]+$"#, with: "$1", options: .regularExpression) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.begin { [weak self] result in
            guard result == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: pdfURL, to: dest)
                DispatchQueue.main.async {
                    self?.setStatus("已保存到 \(dest.path)", .ok)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setStatus("保存失败：\(error.localizedDescription)", .err)
                }
            }
        }
    }

    // MARK: - Helpers

    private func setStatus(_ msg: String, _ kind: StatusKind) {
        statusMessage = msg
        statusKind = kind
    }

    /// 各页物理尺寸（去重后）。用于告警「页面尺寸不一致」。
    ///
    /// 【为何改用 PDFKit】原先调 poppler 的 `pdfinfo` 解析文本输出。而 poppler
    /// 是本项目唯一需要成串动态库（libpoppler / liblcms2 / freetype / fontconfig…）
    /// 的依赖，为把 app 做成自包含可分发，它那棵依赖树的重定位成本远高于收益 ——
    /// 而它在此处只做一件事：读页面尺寸，PDFKit 原生就能做，且免去解析文本、
    /// 免去正则（此前正则漏取捕获组，导致每页都被判为不同尺寸而恒亮告警）。
    ///
    /// mediaBox 与 pdfinfo 的 "Page N size" 同源，故数值与旧实现一致。
    private func getPageSizes(pdf: URL, pages: Int) -> [String] {
        guard let doc = PDFDocument(url: pdf) else { return [] }
        var sizes = Set<String>()
        for i in 0..<min(pages, doc.pageCount) {
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .mediaBox)
            // 保留三位小数并与旧格式一致（"445.323 x 593.858"），
            // 使既有的一致性比较与界面展示无需改动。
            sizes.insert(String(format: "%.3f x %.3f", b.width, b.height))
        }
        return sizes.sorted()
    }

    @discardableResult
    /// 把裸命令名解析为绝对路径；已是绝对路径则原样返回。
    private static func resolveExecutable(_ cmd: String) -> String {
        guard !cmd.hasPrefix("/") else { return cmd }
        // bundle 内自带的引擎优先 —— 目标机可能根本没有 Homebrew。
        var searchPaths: [String] = []
        if let res = Bundle.main.resourceURL {
            searchPaths.append(res.appendingPathComponent("bin").path)
        }
        searchPaths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in searchPaths {
            let candidate = dir + "/" + cmd
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return cmd   // 交给 Process 报错，调用方已有失败分支
    }

    private func runShell(_ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        // executableURL 不做 PATH 查找 —— 设 environment["PATH"] 只影响孙进程。
        // 故裸命令名（"typst"/"pdftoppm"）必须自行解析成绝对路径，
        // 否则从 Finder 启动时必然启动失败（Homebrew 不在 launchd 的默认 PATH 里）。
        proc.executableURL = URL(fileURLWithPath: Self.resolveExecutable(args[0]))
        proc.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            return ("", error.localizedDescription, -1)
        }
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            proc.terminationStatus
        )
    }

    private func shellCommandExists(_ cmd: String) -> Bool {
        let r = runShell(["/bin/sh", "-c", "command -v \(cmd)"])
        return r.exitCode == 0
    }
}
