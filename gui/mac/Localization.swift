import Foundation

/// UI 文案查找。源语言为简体中文，译文在 Localization/Localizable.xcstrings。
/// SwiftUI 的 Text("字面量") 会自动本地化；凡是先成为 String 的文案（状态消息、三元表达式、
/// 存入模型的标签）都要经过这里，否则会原样显示中文。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}
