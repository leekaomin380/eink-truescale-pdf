import Foundation

/// 中继服务配置。存于 App Group，主 App 与 Share Extension 共享。
struct RelayConfig: Codable, Equatable {
    var host: String = ""          // 如 gaomingdemacbook-air.local
    var port: Int = 8790
    var token: String = ""

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var baseURL: URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        return URL(string: "http://\(h):\(port)")
    }

    // MARK: - App Group 持久化

    static let suiteName = "group.com.figedu.sendtoquaderno"
    private static let key = "relayConfig"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func load() -> RelayConfig {
        guard let d = defaults,
              let data = d.data(forKey: key),
              let cfg = try? JSONDecoder().decode(RelayConfig.self, from: data)
        else { return RelayConfig() }
        return cfg
    }

    func save() {
        guard let d = Self.defaults,
              let data = try? JSONEncoder().encode(self) else { return }
        d.set(data, forKey: Self.key)
    }
}
