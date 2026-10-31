import Foundation
import AppKit

@main
struct WebMarkdownTests {
    static func main() throws {
        _ = NSApplication.shared
        let js = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let extractor = WeChatExtractor(extractorJS: js)
        let paragraph = String(repeating: "这是供 AI 阅读的公众号正文，保留中文与段落。", count: 20)
        let html = """
        <html><head><title>测试文章</title></head><body>
        <h1 id="activity-name">测试文章</h1>
        <div id="js_content"><h2>小节</h2><p>\(paragraph)</p>
        <ul><li>第一项</li><li>第二项</li></ul><blockquote>引用正文</blockquote>
        <p><a href="https://example.com/reference">参考资料</a></p>
        <img data-src="https://example.com/image.png" alt="示意图">
        <script>SHOULD_NOT_EXPORT</script><style>SHOULD_NOT_EXPORT</style></div>
        </body></html>
        """
        var finished = false
        var failure: Error?
        extractor.extract(html: html, url: "https://mp.weixin.qq.com/s/test", timeout: 15) { result in
            do {
                let article = try result.get()
                precondition(article.ok)
                let md = ConversionViewModel.webArticleMarkdown(article, sourceURL: "https://mp.weixin.qq.com/s/test")
                for expected in ["测试文章", "source:", "mp.weixin.qq.com", "## 小节", "- 第一项", "> 引用正文", "[参考资料](https://example.com/reference)", "![示意图](https://example.com/image.png)", paragraph] {
                    precondition(md.contains(expected), "Missing: \(expected)")
                }
                precondition(!md.contains("SHOULD_NOT_EXPORT") && !md.contains("base64"))
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
                defer { try? FileManager.default.removeItem(at: file) }
                try md.write(to: file, atomically: true, encoding: .utf8)
                let saved = try String(contentsOf: file, encoding: .utf8)
                precondition(saved == md)
            } catch { failure = error }
            finished = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(finished, "Extraction did not finish")
        if let failure = failure { throw failure }

        let title = "引号\"、反斜线\\、换行\n第二行"
        let article = ExtractedArticle(ok: true, outcome: "OK", title: title, author: "作者", date: "2026-10-03", site: "公众号", markdown: "正文", reason: "")
        let md = ConversionViewModel.webArticleMarkdown(article, sourceURL: "https://example.com/new")
        for (key, value) in [("title", title), ("author", "作者"), ("date", "2026-10-03"), ("site", "公众号"), ("source", "https://example.com/new")] {
            let line = md.components(separatedBy: "\n").first { $0.hasPrefix(key + ": ") }!
            let json = String(line.dropFirst(key.count + 2)).data(using: .utf8)!
            let decoded = try JSONDecoder().decode(String.self, from: json)
            precondition(decoded == value)
        }
        print("PASS: HTML extraction → UTF-8 Markdown; metadata escaping; headings, lists, quotes, links and images; script removal")
    }
}
