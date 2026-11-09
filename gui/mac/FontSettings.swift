import AppKit
import SwiftUI

struct FontChoice: Equatable {
    let family: String
    let title: String
}

/// Both font controls fill the same column; long family names live in tooltips.
struct FontFamilyPicker: NSViewRepresentable {
    let choices: [FontChoice]
    let accessibilityTitle: String
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.choices != choices {
            button.removeAllItems()
            for choice in choices {
                // Add distinct items even when two installed families share a display name.
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice.family
                item.toolTip = choice.family
                button.menu?.addItem(item)
            }
            context.coordinator.choices = choices
        }
        if let index = choices.firstIndex(where: { $0.family == selection }) {
            button.selectItem(at: index)
        }
        button.toolTip = selection
        button.setAccessibilityLabel(accessibilityTitle)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: FontFamilyPicker
        var choices: [FontChoice] = []
        init(_ parent: FontFamilyPicker) { self.parent = parent }
        @objc func changed(_ button: NSPopUpButton) {
            guard let family = button.selectedItem?.representedObject as? String else { return }
            parent.selection = family
        }
    }
}

enum FontSpecimenTypography {
    /// Resolve a concrete regular face, not an ambiguous family alias.
    static func regularFont(family: String, size: CGFloat = 18) -> NSFont {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let candidates: [(NSFont, Int)] = members.compactMap { member in
            guard let name = member[0] as? String,
                  let face = member[1] as? String,
                  let weight = member[2] as? NSNumber,
                  let font = NSFont(name: name, size: size) else { return nil }
            let traits = font.fontDescriptor.symbolicTraits
            let normalFace = ["regular", "roman", "normal"].contains(face.lowercased())
            let penalty = (traits.contains(.bold) ? 100 : 0) + (traits.contains(.italic) ? 100 : 0)
                + (normalFace ? 0 : 10) + abs(weight.intValue - 5)
            return (font, penalty)
        }
        return candidates.min { $0.1 < $1.1 }?.0
            ?? NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
    }

    static func sample(cjkFamily: String, latinFamily: String, traditional: Bool = false) -> AttributedString {
        let cjk = Font(regularFont(family: cjkFamily))
        let latin = Font(regularFont(family: latinFamily))
        let segments: [(String, Font)] = [
            ("山水有清音，阅读见天地。\n", cjk),
            ("The quick brown fox.\n", latin),
            ("中英 ", cjk), ("Aa 0123456789", latin), ("，。！？", cjk)
        ]
        var sample = AttributedString()
        for (text, font) in segments {
            let displayed = traditional
                ? (text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text) : text
            var run = AttributedString(displayed)
            run.font = font
            sample.append(run)
        }
        return sample
    }
}
