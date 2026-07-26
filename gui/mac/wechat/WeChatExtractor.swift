// WeChatExtractor.swift — WKWebView 端侧抽取宿主
//
// 职责边界：**只做宿主，不做抽取**。抽取逻辑只有一份，在 wechat_extractor.js 里 ——
// 那是它能 OTA 热更新的前提（微信改版时改服务端的 JS，全员立刻生效；若把逻辑搬进
// Swift，就退化成"必须过 Apple 审核才能修"，而抽取逻辑恰恰是最需要热修的部分）。
//
// 设计依据全部是 2026-07-17 实测，不是推演：
//   · WKWebView 会真的去拉绝对 URL —— `baseURL:nil` 只挡相对地址。实测把
//     <img src="http://127.0.0.1:PORT/CANARY.jpg"> 放进 HTML，本地监听器【被打到】。
//     真实微信文章含 5 个 mmbiz.qpic.cn 绝对 URL → 不挡 = 泄露用户在读哪篇文章
//     + 可能触发微信反爬 + 白等 CDN（参考实现 1393ms 里有相当一部分在等图）。
//   · WKWebView 的 DOM 解析在【独立的 WebContent XPC 进程】里（已抓到进程确认）。
//     它可能被系统单独杀掉 → 不处理则回调永不触发，调用方永远等下去。
//   · `compileContentRuleList` 在命令行环境下【工作正常】（实测 24ms 回调）。
//
// ★ 为什么用 WKContentRuleList，而不是"加载前把 URL 从 HTML 里删掉"：
//   删 URL 是【黑名单】，永远数不全 —— 实测 6/6 漏（单引号 src、无引号 src、
//   CSS background-image、iframe、video、style @import 全部照发请求）。
//   WKContentRuleList 在 WebKit 的网络层拦截，是【全量 block】，不依赖枚举标签写法。
//   更要命的是：删 URL 会连 <img> 标签一起删掉（实测真实文章 13 → 5 个、
//   图片 URL 10 → 2），而【下一个功能（带图投递）正是靠这些 data-src URL】。
//
//   **原则：要阻断的是「请求」，不是「信息」。HTML 一个字都不该动。**
import Foundation
import WebKit

struct ExtractedArticle {
    let ok: Bool
    let outcome: String       // OK | EXTRACT_EMPTY | STRUCT_MISSING | CONTENT_GONE | RISK_GRAY
    let title: String
    let author: String?
    let date: String?
    let site: String?
    let markdown: String
    let reason: String
}

enum ExtractionError: Error, CustomStringConvertible {
    case timeout
    case webContentTerminated
    case navigationFailed(String)
    case javaScriptFailed(String)
    case badResult(String)
    case ruleListUnavailable(String)

    var description: String {
        switch self {
        case .timeout: return "timeout"
        case .webContentTerminated: return "webContentTerminated"
        case .navigationFailed(let m): return "navigationFailed(\(m))"
        case .javaScriptFailed(let m): return "javaScriptFailed(\(m))"
        case .badResult(let m): return "badResult(\(m))"
        case .ruleListUnavailable(let m): return "ruleListUnavailable(\(m))"
        }
    }
}

final class WeChatExtractor: NSObject, WKNavigationDelegate {

    // 全量 block：不枚举标签、不猜属性写法 —— 任何 URL 都不许出网。
    private static let blockAllRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    private static let ruleIdentifier = "readisland.blockAll.v1"
    private static var cachedRuleList: WKContentRuleList?

    private let extractorJS: String

    // 【必须持有到回调结束】提前释放 = WebView 被回收 = 回调静默不触发。
    private var webView: WKWebView?
    private var completion: ((Result<ExtractedArticle, Error>) -> Void)?
    private var currentURL: String = ""
    private var timeoutItem: DispatchWorkItem?

    // ★ 在飞期间【自持】—— 不要求调用方记得持有本对象。
    //
    // 缘由（自己踩的坑，由 C1/C2 测试当场抓到）：本类内部到处是 [weak self]（必须的，
    // 否则超时闭包会与 self 循环引用）。若调用方写成
    //     WeChatExtractor(extractorJS: js).extract(...) { ... }
    // 这种临时对象，ARC 会在 extract 返回后立刻回收它 → 所有 [weak self] 拿不到 self
    // → **回调永不触发，且完全静默**：调用方永远等下去，没有错误、没有日志。
    //
    // "要求调用方记得持有"是个陷阱型 API —— 忘了不会报错，只会挂起。Share Extension
    // 里挂起 = 被系统杀掉 = 用户看到"分享失败"且无任何信息。故由本类自己兜住。
    private var selfRetain: WeChatExtractor?

    init(extractorJS: String) {
        self.extractorJS = extractorJS
        super.init()
    }

    /// 抽取。**必须在主线程调用** —— WKWebView 是主线程限定的。
    /// completion 在主线程回调，且**保证恰好一次**（超时/进程终止/成功/失败都收敛到 finish）。
    func extract(html: String,
                 url: String,
                 timeout: TimeInterval = 20,
                 completion: @escaping (Result<ExtractedArticle, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.completion = completion
        self.currentURL = url
        self.selfRetain = self          // 在飞期间自持，finish 里释放

        Self.obtainRuleList { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e):
                // ★ 拿不到规则表 = 挡不住网络 → **拒绝抽取**，绝不降级裸跑。
                // 宁可这次失败（客户端回退到服务端轨道，用户只是慢一点），
                // 也不能把"用户在读哪篇文章"泄露给腾讯 CDN。
                self.finish(.failure(ExtractionError.ruleListUnavailable("\(e)")))
            case .success(let list):
                self.startLoad(html: html, ruleList: list, timeout: timeout)
            }
        }
    }

    private func startLoad(html: String, ruleList: WKContentRuleList, timeout: TimeInterval) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(ruleList)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        let item = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ExtractionError.timeout))
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)

        // baseURL:nil 挡相对地址，ruleList 挡绝对地址 —— 两者互补，缺一不可。
        // **HTML 原样传入，一个字都不改**：带图功能要靠里面的 data-src URL。
        wv.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = extractorJS + "\n"
            + "JSON.stringify(readislandExtract(document, \(jsStringLiteral(currentURL))))"
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self = self else { return }
            if let error = error {
                self.finish(.failure(ExtractionError.javaScriptFailed("\(error)")))
                return
            }
            guard let json = value as? String, let data = json.data(using: .utf8) else {
                self.finish(.failure(ExtractionError.badResult("JS 未返回字符串")))
                return
            }
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.finish(.failure(ExtractionError.badResult("JS 返回的不是合法 JSON")))
                return
            }
            self.finish(.success(ExtractedArticle(
                ok: (o["ok"] as? Bool) ?? false,
                outcome: (o["outcome"] as? String) ?? "",
                title: (o["title"] as? String) ?? "",
                author: o["author"] as? String,
                date: o["date"] as? String,
                site: o["site"] as? String,
                markdown: (o["markdown"] as? String) ?? "",
                reason: (o["reason"] as? String) ?? ""
            )))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ExtractionError.navigationFailed("\(error)")))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ExtractionError.navigationFailed("provisional: \(error)")))
    }

    /// WebContent 是独立 XPC 进程，可能被系统单独杀掉（内存压力等）。
    /// **不实现本方法 = 那种情况下回调永不触发 = 调用方永远等下去。**
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ExtractionError.webContentTerminated))
    }

    // MARK: - 内部

    /// 收敛点：**保证恰好调用一次**。超时与真实结果会赛跑，这里负责去重。
    private func finish(_ result: Result<ExtractedArticle, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let cb = completion else { return }   // 已收敛过
        completion = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        cb(result)
        // 放在最后：先把结果交出去，再撤自持。顺序反了会让 self 在 cb 跑完前被回收。
        selfRetain = nil
    }

    /// 把 Swift 字符串安全地变成 JS 字符串字面量（URL 里可能有引号/反斜杠）。
    private func jsStringLiteral(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())   // ["x"] → "x"
    }

    private static func obtainRuleList(_ done: @escaping (Result<WKContentRuleList, Error>) -> Void) {
        if let cached = cachedRuleList {
            DispatchQueue.main.async { done(.success(cached)) }
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleIdentifier, encodedContentRuleList: blockAllRules
        ) { list, error in
            DispatchQueue.main.async {
                if let list = list {
                    cachedRuleList = list
                    done(.success(list))
                } else {
                    done(.failure(error ?? ExtractionError.ruleListUnavailable("compile 返回空且无错误")))
                }
            }
        }
    }
}
