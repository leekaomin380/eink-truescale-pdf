import AppKit
import SwiftUI

/// Keep the editable source as Markdown, including formatting carried by a normal paste.
/// A native text view preserves insertion position, selection replacement and undo.
struct MarkdownPasteEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = MarkdownPasteTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 5, height: 8)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
        editor.breakUndoCoalescing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownPasteEditor
        init(_ parent: MarkdownPasteEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

final class MarkdownPasteTextView: NSTextView {
    override func paste(_ sender: Any?) {
        paste(from: .general)
    }

    // Separate entry point also permits tests without touching the user's clipboard.
    func paste(from pasteboard: NSPasteboard) {
        guard let markdown = RichTextMarkdown.read(pasteboard) else {
            super.paste(nil)
            return
        }
        insertText(markdown, replacementRange: selectedRange())
    }
}

enum RichTextMarkdown {
    static func read(_ pasteboard: NSPasteboard) -> String? {
        let plain = pasteboard.string(forType: .string)
        // Prefer HTML for semantic headings/tables; RTF covers Word and native note apps.
        for (type, format) in [(NSPasteboard.PasteboardType.html, "html"), (.rtf, "rtf")] {
            if let data = pasteboard.data(forType: type),
               let markdown = convert(data, format: format) {
                return markdown
            }
        }
        return plain
    }

    static func convert(_ data: Data, format: String) -> String? {
        guard !data.isEmpty else { return nil }
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("truescale-paste-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: input) }
        do { try data.write(to: input) } catch { return nil }
        var candidates = [String]()
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("bin/pandoc").path)
        }
        candidates += ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Drop presentation wrappers and raw HTML, retaining semantic content as editable Markdown.
        process.arguments = [input.path, "--from", format, "--to",
            "markdown-fenced_divs-bracketed_spans-native_divs-native_spans-raw_html-raw_attribute-header_attributes-link_attributes-simple_tables-multiline_tables-grid_tables",
            "--wrap=none"]
        let result = ProcessRunner.run(process, mode: .separate, timeout: 3)
        guard result.exitCode == 0, !result.timedOut, result.launchError.isEmpty,
              let markdown = String(data: result.stdout, encoding: .utf8),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Only remove the writer's trailing newline; indentation may be meaningful code.
        return markdown.replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
    }
}
