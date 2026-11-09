import AppKit
import Foundation
import PDFKit

// Rendering checks never send to a device; fail immediately if that boundary is crossed.
struct DeviceFilesModel {
    static let shared = DeviceFilesModel()
    func noteDelivered(name: String) { preconditionFailure("Unexpected device delivery") }
}

@main
struct PreviewFreshnessTests {
    static func waitFor(_ condition: () -> Bool, seconds: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Timed out waiting for rendering")
    }

    static func main() throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = ConversionViewModel(repositoryURL: repo)
        model.activeKind = .text
        model.printTime = false
        model.pasteText = """
        ---
        title: 源文旧标题
        ---
        第一段：这是信用卡历史的测试正文。
        第二段：这一行必须在新的一行开始。
        * 无担保：保留第一项。
        * 循环：保留第二项。
        """
        model.pasteTitle = "初始标题"
        var firstDone = 0
        var secondDone = 0
        model.ensureFresh { firstDone += 1 }
        precondition(model.isConverting)
        // Change input while the first process is running, then request a send/save equivalent.
        model.pasteTitle = "信用卡的历史：最新标题"
        model.pasteText += "\n\n最后补充的正文。"
        model.ensureFresh { secondDone += 1 }
        waitFor { firstDone == 1 && secondDone == 1 }
        precondition(model.renderGeneration == 2, "Expected one serialized follow-up render")
        precondition(!model.isStale && !model.isConverting)
        let pdf = PDFDocument(url: model.currentPdfURL!)!
        let text = pdf.string ?? ""
        for expected in ["信用卡的历史", "最新标题", "第一段", "第二段", "无担保", "循环", "最后补充"] {
            precondition(text.contains(expected), "Missing PDF text: \(expected)\n\(text)")
        }
        precondition(!text.contains("初始标题") && !text.contains("源文旧标题"))
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.copyItem(at: model.currentPdfURL!, to: output)
        // A title-only edit also invalidates and refreshes the existing PDF.
        model.pasteTitle = "只修改标题也会更新"
        precondition(model.isStale)
        var titleDone = false
        model.ensureFresh { titleDone = true }
        waitFor { titleDone }
        precondition(!model.isStale)
        precondition(PDFDocument(url: model.currentPdfURL!)!.string!.contains("只修改标题也会更新"))
        let generation = model.renderGeneration
        var cached = false
        model.ensureFresh { cached = true }
        precondition(cached && model.renderGeneration == generation && !model.isConverting)
        // Validation errors drain callbacks and allow a subsequent valid attempt.
        model.pasteText = ""
        var invalidDelivered = false
        model.ensureFresh { invalidDelivered = true }
        precondition(!model.isConverting && !invalidDelivered)
        model.pasteText = "恢复有效正文。"
        var recovered = false
        model.ensureFresh { recovered = true }
        waitFor { recovered }
        precondition(!invalidDelivered)
        let sharedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quaderno Converter/clipboard-layout.json")
        let sharedBefore = try? Data(contentsOf: sharedURL)
        model.bodySize = "10.5pt"
        model.margin = "12mm"
        model.leading = "0.7em"
        model.pagePresetID = "a4"
        precondition(model.bodySize == "12pt" && model.margin == "16mm")
        model.bodySize = "14pt"
        model.margin = "8mm"
        model.pagePresetID = "device"
        precondition(model.bodySize == "10.5pt" && model.margin == "12mm" && model.leading == "0.7em")
        precondition(model.config.pageW == "157.1mm" && model.config.pageH == "209.5mm")
        model.pagePresetID = "a4"
        precondition(model.bodySize == "14pt" && model.margin == "8mm")
        for paper in StandardPaper.all {
            model.pagePresetID = paper.id
            model.landscape = false
            var ready = false
            model.ensureFresh { ready = true }
            waitFor { ready }
            let document = PDFDocument(url: model.currentPdfURL!)!
            for index in 0..<document.pageCount {
                let bounds = document.page(at: index)!.bounds(for: .mediaBox)
                precondition(abs(bounds.width - paper.width * 72 / 25.4) < 0.1)
                precondition(abs(bounds.height - paper.height * 72 / 25.4) < 0.1)
            }
        }
        model.pagePresetID = "a4"
        model.landscape = true
        var landscapeReady = false
        model.ensureFresh { landscapeReady = true }
        waitFor { landscapeReady }
        let landscapeBounds = PDFDocument(url: model.currentPdfURL!)!.page(at: 0)!.bounds(for: .mediaBox)
        precondition(abs(landscapeBounds.width - 297 * 72 / 25.4) < 0.1)
        precondition(abs(landscapeBounds.height - 210 * 72 / 25.4) < 0.1)
        precondition(sharedBefore == (try? Data(contentsOf: sharedURL)))
        for symbol in ["doc", "textformat", "textformat.size", "arrow.up.and.down", "rectangle.dashed", "clock", "paperplane", "square.and.arrow.down", "rectangle.portrait", "slider.horizontal.3"] {
            precondition(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Missing symbol: \(symbol)")
        }
        let originalText = "简体中文，发展、头发与皇后。\n\n`简体代码`"
        model.pasteText = originalText
        model.pasteTitle = "简体标题"
        model.renderTraditional = true
        precondition(model.isStale)
        var traditionalReady = false
        model.ensureFresh { traditionalReady = true }
        waitFor { traditionalReady }
        let traditionalText = PDFDocument(url: model.currentPdfURL!)!.string ?? ""
        precondition(traditionalText.contains("簡體標題"))
        precondition(traditionalText.contains("簡體中文"))
        precondition(traditionalText.contains("頭髮"))
        precondition(traditionalText.contains("简体代码"))
        precondition(model.pasteText == originalText && model.pasteTitle == "简体标题")
        model.renderTraditional = false
        precondition(model.isStale)
        // Render validation failure must clear busy state without ever contacting a device.
        model.pasteText = ""
        model.requestDelivery()
        precondition(!model.isDelivering && model.deliveryProgress == nil)
        var events: [DeliveryProgress] = []
        let decoder = DeliveryProgressDecoder { events.append($0) }
        decoder.feed(Data("noise\n{\"kind\":\"progress\",\"phase\":\"upload\",\"fraction\":".utf8))
        precondition(events.isEmpty)
        decoder.feed(Data("0.42}\n{\"kind\":\"progress\",\"phase\":\"confirm\"}\n".utf8))
        precondition(events.count == 2 && events[0].fraction == 0.42 && events[1].fraction == nil)
        print("PASS: traditional output preserves source/code; toggle invalidates PDF; failed render clears delivery busy state; streamed progress decoder")
        print("PASS: five standard paper MediaBoxes; landscape; separate typography; clipboard profile unchanged; system symbols")
        print("PASS: edits during render; serialized refresh; title-only edit; YAML title override; latest PDF before actions; cached PDF reuse; empty-input recovery")
    }
}
