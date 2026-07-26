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
    @Published var statusMessage = ""
    @Published var statusKind: StatusKind = .info
    @Published var isConverting = false

    @Published var currentPdfURL: URL?
    @Published var totalPages = 0
    @Published var currentPage = 1
    @Published var renderMetrics: RenderMetrics?
    @Published var hasQuaderno = false
    @Published var hasPoppler = false

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

    var selectedDevice: DeviceInfo? {
        guard selectedDeviceIndex < devices.count else { return nil }
        return devices[selectedDeviceIndex]
    }

    init() {
        let scriptDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        repoURL = scriptDir

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
            let poppler = self.shellCommandExists("pdftoppm")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cjkFonts = fonts.cjk
                self.latinFonts = fonts.latin
                self.hasPoppler = poppler
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
            config.fonts = fontStr.components(separatedBy: "\"").filter {
                !$0.isEmpty && $0 != "FONTS=(" && $0 != ")"
            }
        }

        bodySize = config.bodySize
        margin = config.margin
        leading = config.leading
        docLang = config.docLang
        if config.fonts.count >= 2 {
            selectedLatinFont = config.fonts[0]
            selectedCjkFont = config.fonts[1]
        }
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
        let pageWmm = Double(margin.replacingOccurrences(of: "mm", with: "")) ?? 10
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
                "--page", config.pageW, config.pageH
            ])

            DispatchQueue.main.async { [self] in
                isConverting = false
                if result.exitCode != 0 {
                    setStatus("渲染失败：\(result.stderr.suffix(200))", .err)
                    return
                }
                self.currentPdfURL = outPdf
                let info = PDFDocument(url: outPdf)
                self.totalPages = info?.pageCount ?? 0
                self.currentPage = 1
                let sizes = getPageSizes(pdf: outPdf, pages: self.totalPages)
                self.renderMetrics = computeMetrics(pages: self.totalPages, pageSizes: sizes)
                setStatus("渲染完成，共 \(self.totalPages) 页", .ok)
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
                "--plain"
            ])

            DispatchQueue.main.async { [self] in
                isConverting = false
                if result.exitCode != 0 {
                    setStatus("渲染失败：\(result.stderr.suffix(200))", .err)
                    return
                }
                self.currentPdfURL = outPdf
                let info = PDFDocument(url: outPdf)
                self.totalPages = info?.pageCount ?? 0
                self.currentPage = 1
                let sizes = getPageSizes(pdf: outPdf, pages: self.totalPages)
                self.renderMetrics = computeMetrics(pages: self.totalPages, pageSizes: sizes)
                setStatus("渲染完成，共 \(self.totalPages) 页", .ok)
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

    private func getPageSizes(pdf: URL, pages: Int) -> [String] {
        let r = runShell(["pdfinfo", "-f", "1", "-l", "\(pages)", pdf.path])
        guard r.exitCode == 0 else { return [] }
        let pattern = #"Page\s+\d+ size:\s+([\d.]+ x [\d.]+)"#
        var sizes = Set<String>()
        for line in r.stdout.components(separatedBy: "\n") {
            if let range = line.range(of: pattern, options: .regularExpression) {
                sizes.insert(String(line[range]))
            }
        }
        return sizes.sorted()
    }

    @discardableResult
    private func runShell(_ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
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
