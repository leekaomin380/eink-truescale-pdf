import AppKit
import Foundation

@main
struct RichTextPasteTests {
    static func main() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("原始纯文字", forType: .string)
        precondition(RichTextMarkdown.read(board) == "原始纯文字")
        let literal = "# 标题\n\n$PATH @mention \\(x^2\\)\n\n```sh\necho test\n```\n"
        board.clearContents()
        board.setString(literal, forType: .string)
        precondition(RichTextMarkdown.read(board) == literal)

        board.clearContents()
        board.setString("标题\n粗体列表表格已变平", forType: .string)
        board.setString("""
        <html><body><h2>标题</h2><p><strong>粗体</strong> <em>斜体</em></p>
        <ul><li>第一项</li><li>第二项</li></ul><blockquote>引用</blockquote>
        <p><a href="https://example.com">参考</a></p>
        <table><tr><th>科目</th><th>费用</th></tr><tr><td>学费</td><td>100</td></tr></table>
        <pre><code>print("hello")</code></pre></body></html>
        """, forType: .html)
        let md = RichTextMarkdown.read(board)!
        for expected in ["## 标题", "**粗体**", "*斜体*", "第一项", "> 引用", "[参考](https://example.com)", "科目", "学费", "100", "print(\"hello\")"] {
            precondition(md.contains(expected), "Missing \(expected): \(md)")
        }
        // Check semantics through Pandoc's reader, rather than just Markdown delimiters.
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: input) }
        try md.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/pandoc")
        process.arguments = [input.path, "-t", "native"]
        let ast = ProcessRunner.run(process, mode: .separate, timeout: 5)
        precondition(ast.exitCode == 0)
        let tree = String(decoding: ast.stdout, as: UTF8.self)
        for node in ["Header", "Strong", "Emph", "BulletList", "BlockQuote", "Link", "Table", "CodeBlock"] {
            precondition(tree.contains(node), "Missing AST node: \(node)")
        }

        // Paste at the selection, keep surrounding text, and undo/redo the full insertion.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = MarkdownPasteTextView(frame: window.contentView!.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        window.contentView!.addSubview(editor)
        window.makeFirstResponder(editor)
        editor.string = "前文 待替换 后文"
        editor.setSelectedRange(NSRange(location: 3, length: 3))
        editor.paste(from: board)
        precondition(editor.string == "前文 " + md + " 后文")
        editor.undoManager!.undo()
        precondition(editor.string == "前文 待替换 后文")
        editor.undoManager!.redo()
        precondition(editor.string == "前文 " + md + " 后文")

        let rich = NSMutableAttributedString(string: "加粗正文")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 2))
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.clearContents()
        board.setData(rtf, forType: .rtf)
        precondition(RichTextMarkdown.read(board)!.contains("**加粗**"))
        print("PASS: HTML/RTF → Markdown → semantic AST; literal Markdown; selection replacement; undo/redo")
    }
}
