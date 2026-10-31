import Foundation

/// UI 文案查找。源语言为简体中文，译文在 Localization/Localizable.xcstrings。
/// SwiftUI 的 Text("字面量") 会自动本地化；凡是先成为 String 的文案（状态消息、三元表达式、
/// 存入模型的标签）都要经过这里，否则会原样显示中文。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppLanguage.bundle)
}

/// 子进程环境：让直连工具与 deliver.sh 的消息语言跟随 App 界面语言。
func helperEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["QUADERNO_LANG"] = AppLanguage.chosen ?? Bundle.main.preferredLocalizations.first ?? "en"
    return environment
}

/// 设置页选择的界面语言（zh-Hans / en / ja），nil 为跟随系统。
/// 用本 App 自己的键保存：系统会特殊处理 AppleLanguages（persistentDomain 读不到它，实测）。
/// 直连工具读同一个键，所以 Ctrl+1 的通知语言也一致。
enum AppLanguage {
    static let key = "AppLanguage"

    static var chosen: String? {
        let value = UserDefaults.standard.string(forKey: key)
        return value?.isEmpty == false ? value : nil
    }

    /// 界面字符串表在进程启动时就按系统语言选定，之后改 AppleLanguages 无效（实测），
    /// 所以按所选语言直接取对应 .lproj：SwiftUI 文案经根视图的 \.locale，其余经 L()。
    static let bundle: Bundle = {
        guard let chosen, let path = Bundle.main.path(forResource: chosen, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }()

    static var locale: Locale { chosen.map(Locale.init(identifier:)) ?? .autoupdatingCurrent }
}
