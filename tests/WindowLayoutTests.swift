import AppKit
import SwiftUI
import Vision

@main
struct WindowLayoutTests {
    @MainActor
    static func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(true, forKey: Pairing.guideDismissedKey)
        UserDefaults.standard.set(true, forKey: "isAdvancedExpanded")
        let model = ConversionViewModel(repositoryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        model.activeKind = .text
        model.hasQuaderno = true
        model.devices = [DeviceInfo(name: "QUADERNO A5", vendor: "Fujitsu", models: ["FMVDP51"],
            sizeClass: "10.3in-3x4", resolutionPx: [1404, 1872], ppi: 227.18,
            displayBehavior: "exact-fit", behaviorVerified: true, displayMm: [157.1, 209.5],
            sizeVerified: true, diagonalIn: 10.3)]
        model.pasteTitle = "窗口布局验证"
        model.pasteText = String(repeating: "## 阅读材料\n\n正文支持滚动，设置与操作按钮都应可以访问。\n\n", count: 40)
        model.cjkFonts = ["Noto Serif CJK SC"]
        model.selectedCjkFont = "Noto Serif CJK SC"
        model.latinFonts = ["Times New Roman"]
        model.selectedLatinFont = "Times New Roman"
        model.renderMetrics = RenderMetrics(pages: 3)
        model.totalPages = 3
        let host = NSHostingView(rootView: ContentView(viewModel: model, initialMode: .text))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1080, height: 720), NSSize(width: 1280, height: 800)] {
            window.setContentSize(size)
            pump()
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let composite = NSImage(size: host.bounds.size)
            composite.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: host.bounds.size).fill()
            NSImage(cgImage: bitmap.cgImage!, size: host.bounds.size).draw(in: NSRect(origin: .zero, size: host.bounds.size))
            composite.unlockFocus()
            let rendered = NSBitmapImageRep(data: composite.tiffRepresentation!)!
            try rendered.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("layout-\(Int(size.width))x\(Int(size.height)).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: rendered.cgImage!).perform([request])
            let observations = request.results ?? []
            for name in ["刷新预览", "投递到QUADERNO", "另存PDF", "导出Markdown"] {
                let matches = observations.filter {
                    ($0.topCandidates(1).first?.string ?? "").replacingOccurrences(of: " ", with: "").contains(name)
                }
                precondition(!matches.isEmpty, "Missing visible action \(name): \(observations.compactMap { $0.topCandidates(1).first?.string })")
                precondition(matches.contains { $0.boundingBox.minY > 0.005 && $0.boundingBox.maxY < 0.995 }, "Clipped action: \(name)")
            }
            print("PASS: footer actions within \(Int(size.width)) × \(Int(size.height)) window")
        }
        model.pagePresetID = "a4"
        window.setContentSize(NSSize(width: 900, height: 600))
        pump()
        host.layoutSubtreeIfNeeded()
        guard let paperBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No paper bitmap") }
        host.cacheDisplay(in: host.bounds, to: paperBitmap)
        let paperComposite = NSImage(size: host.bounds.size)
        paperComposite.lockFocus()
        NSColor.white.setFill()
        host.bounds.fill()
        NSImage(cgImage: paperBitmap.cgImage!, size: host.bounds.size).draw(in: host.bounds)
        paperComposite.unlockFocus()
        let paperRendered = NSBitmapImageRep(data: paperComposite.tiffRepresentation!)!
        try paperRendered.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("paper-900x600.png"))
        let paperRequest = VNRecognizeTextRequest()
        paperRequest.recognitionLevel = .accurate
        paperRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: paperRendered.cgImage!).perform([paperRequest])
        let paperLabels = (paperRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        precondition(paperLabels.contains { $0.replacingOccurrences(of: " ", with: "").contains("另存PDF") })
        precondition(!paperLabels.contains { $0.contains("投递到") })
        print("PASS: standard paper prioritises PDF export at minimum window size")
        model.cjkFonts += ["Noto Sans CJK SC", "LXGW Neo ZhiSong", "Kaiti SC", "STFangsong"]
        model.latinFonts += ["Baskerville"]
        model.selectedCjkFont = "Noto Sans CJK SC"
        model.selectedLatinFont = "Baskerville"
        pump()
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }.filter {
            $0.documentView != nil && !($0.documentView is NSTextView)
        }
        guard let settingsScroll = scrolls.max(by: {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        }), let documentView = settingsScroll.documentView else { fatalError("No settings scroll view") }
        let bottom = documentView.isFlipped
            ? max(0, documentView.bounds.height - settingsScroll.contentView.bounds.height) : 0
        settingsScroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        settingsScroll.reflectScrolledClipView(settingsScroll.contentView)
        pump()
        guard let specimenBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No specimen bitmap") }
        host.cacheDisplay(in: host.bounds, to: specimenBitmap)
        let specimenComposite = NSImage(size: host.bounds.size)
        specimenComposite.lockFocus()
        NSColor.white.setFill()
        host.bounds.fill()
        NSImage(cgImage: specimenBitmap.cgImage!, size: host.bounds.size).draw(in: host.bounds)
        specimenComposite.unlockFocus()
        let specimenRendered = NSBitmapImageRep(data: specimenComposite.tiffRepresentation!)!
        try specimenRendered.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("font-specimens-900x600.png"))
        let specimenRequest = VNRecognizeTextRequest()
        specimenRequest.recognitionLevel = .accurate
        specimenRequest.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: specimenRendered.cgImage!).perform([specimenRequest])
        let specimenLabels = (specimenRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        precondition(specimenLabels.filter { $0.contains("中英混排样张") }.count == 1, "Missing mixed specimen: \(specimenLabels)")
        precondition(FontSpecimenTypography.regularFont(family: "Charter").fontName == "Charter-Roman")
        for family in ["STFangsong", "Noto Sans CJK SC", "LXGW Neo ZhiSong", "Kaiti SC", "Baskerville"] {
            let font = FontSpecimenTypography.regularFont(family: family)
            precondition(!font.fontDescriptor.symbolicTraits.contains(.bold))
            precondition(!font.fontDescriptor.symbolicTraits.contains(.italic))
        }
        let sample = FontSpecimenTypography.sample(cjkFamily: "STFangsong", latinFamily: "Charter")
        precondition(String(sample.characters).contains("中英 Aa 0123456789"))
        precondition(sample.runs.count >= 4)
        let pickers = descendants(host).compactMap { $0 as? NSPopUpButton }
        guard let cjkPicker = pickers.first(where: { $0.accessibilityLabel() == "中文字体" }),
              let latinPicker = pickers.first(where: { $0.accessibilityLabel() == "西文字体（英文与数字）" }) else {
            fatalError("Missing native font pickers")
        }
        precondition(abs(cjkPicker.frame.width - latinPicker.frame.width) < 0.5)
        precondition(cjkPicker.selectedItem?.title == "思源黑体")
        precondition(cjkPicker.toolTip == "Noto Sans CJK SC")
        guard let index = cjkPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == "STFangsong" }) else {
            fatalError("Missing font menu choice")
        }
        cjkPicker.selectItem(at: index)
        NSApp.sendAction(cjkPicker.action!, to: cjkPicker.target, from: cjkPicker)
        pump()
        precondition(model.selectedCjkFont == "STFangsong")
        print("PASS: mixed specimen; explicit regular faces; reachable at minimum window size")
        func visibleLabels() throws -> [String] {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let canvas = NSImage(size: host.bounds.size)
            canvas.lockFocus()
            NSColor.white.setFill()
            host.bounds.fill()
            NSImage(cgImage: bitmap.cgImage!, size: host.bounds.size).draw(in: host.bounds)
            canvas.unlockFocus()
            let image = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        model.margin = "8mm"
        pump(0.5)
        let marginLabels = try visibleLabels()
        precondition(marginLabels.contains { $0.contains("设置示意") }, "Missing margin guide: \(marginLabels)")
        precondition(model.renderGeneration == 0 && !model.isConverting)
        pump(2.8)
        let fadedLabels = try visibleLabels()
        precondition(!fadedLabels.contains { $0.contains("设置示意") })
        model.printTime.toggle()
        pump(0.5)
        let footerLabels = try visibleLabels()
        precondition(footerLabels.contains { $0.contains("页脚时间") })
        precondition(footerLabels.contains { $0.contains("设置示意") })
        precondition(model.renderGeneration == 0 && !model.isConverting)
        print("PASS: margin/footer guides appear, fade and never render a PDF")
        // Content changes must remain idle beyond the old debounce interval.
        model.pasteTitle = "改标题也不自动渲染"
        model.pasteText += "追加文字。"
        model.bodySize = "12pt"
        pump(2)
        precondition(model.renderGeneration == 0 && !model.isConverting && model.currentPdfURL == nil)
        print("PASS: typing, title and layout changes do not trigger typesetting")
        window.orderOut(nil)
    }
}
