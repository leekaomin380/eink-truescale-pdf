import Foundation

/// iphone_relay.py 的响应体（仅取客户端关心的字段）
struct DeliveryResult: Decodable, Equatable {
    let ok: Bool
    let status: String?
    let detail: String?
    let title: String?
    let pages: Int?
    let error: String?

    var displayText: String {
        if let error, !error.isEmpty { return "❌ " + error }
        guard let status else { return "⚠️ 未知响应" }
        switch status {
        case "delivered":
            return "✅ 已投递 · \(title ?? "")" + (pages.map { " · \($0) 页" } ?? "")
        case "offline":      return "📵 \(detail ?? "设备离线")"
        case "cancelled":    return "🚫 \(detail ?? "投递被取消")"
        case "client-missing": return "⚠️ \(detail ?? "Mac 上未找到 QUADERNO 客户端")"
        default:             return "⚠️ \(detail ?? "未确认送达，请检查设备连接")"
        }
    }
}

enum RelayError: LocalizedError {
    case notConfigured
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置服务器与 token，请在 App 中完成设置"
        case .badResponse(let code): return "服务器返回 HTTP \(code)"
        }
    }
}

/// 与 Mac 中继服务（relay/iphone_relay.py）通信的最小客户端。
enum RelayClient {

    struct Payload: Encodable {
        let type: String      // "text" | "url"
        var content: String?  // type=text
        var url: String?      // type=url
        var title: String?
    }

    /// 投递。text 渲染为纯正文版式；url 由 Mac 端抽取正文后排版。
    static func deliver(_ payload: Payload, config: RelayConfig) async throws -> DeliveryResult {
        guard config.isConfigured, let base = config.baseURL else {
            throw RelayError.notConfigured
        }
        var req = URLRequest(url: base.appendingPathComponent("deliver"))
        req.httpMethod = "POST"
        req.setValue(config.token, forHTTPHeaderField: "X-Relay-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120          // 文章抓取+渲染+投递可达数十秒
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw RelayError.badResponse(-1)
        }
        guard let decoded = try? JSONDecoder().decode(DeliveryResult.self, from: data) else {
            throw RelayError.badResponse(http.statusCode)
        }
        return decoded
    }

    /// 连通性测试：GET /health
    static func health(config: RelayConfig) async throws -> Bool {
        guard let base = config.baseURL else { throw RelayError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        struct Health: Decodable { let ok: Bool }
        return (try? JSONDecoder().decode(Health.self, from: data))?.ok ?? false
    }
}

/// 投递历史（App Group 存储，主 App 与扩展共享，上限 50 条）
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var kind: String        // text | url
    var status: String
    var pages: Int?
    var timestamp: Date

    var timeText: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: timestamp)
    }
}

enum HistoryStore {
    private static let key = "deliveryHistory"
    private static let cap = 50

    static func load() -> [HistoryEntry] {
        guard let d = RelayConfig.defaults,
              let data = d.data(forKey: key),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return list
    }

    static func append(_ entry: HistoryEntry) {
        guard let d = RelayConfig.defaults else { return }
        var list = load()
        list.insert(entry, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        if let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: key)
        }
    }

    static func clear() {
        RelayConfig.defaults?.removeObject(forKey: key)
    }
}
