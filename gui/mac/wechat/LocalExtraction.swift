import Foundation

enum LocalExtraction {

    static let minBodyChars = 200

    private static var extractorJS: String? = {
        guard let url = Bundle.main.url(forResource: "wechat_extractor", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s
    }()

    struct Outcome {
        let article: ExtractedArticle?
        let elapsedMs: Int
        let reason: String
    }

    static func run(html: String, url: String,
                    completion: @escaping (Outcome) -> Void) {
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

        guard let js = extractorJS else {
            completion(Outcome(article: nil, elapsedMs: ms(), reason: "js_not_bundled"))
            return
        }
        let extractor = WeChatExtractor(extractorJS: js)
        extractor.extract(html: html, url: url, timeout: 20) { result in
            switch result {
            case .failure(let e):
                completion(Outcome(article: nil, elapsedMs: ms(), reason: "\(e)"))
            case .success(let a):
                guard a.ok, a.outcome == "OK", a.markdown.count >= minBodyChars else {
                    completion(Outcome(article: nil, elapsedMs: ms(),
                                       reason: "outcome=\(a.outcome),len=\(a.markdown.count)"))
                    return
                }
                completion(Outcome(article: a, elapsedMs: ms(), reason: ""))
            }
        }
    }
}
