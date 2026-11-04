import Foundation

/// Shared transport for manual App delivery and connection diagnostics.
/// Credentials remain outside the bundle; the helper verifies the paired device's key.
enum DirectDelivery {
    struct Result {
        let success: Bool
        let message: String
        let details: String
    }

    static func run(_ arguments: [String], environment extra: [String: String] = [:]) async -> Result {
        await Task.detached(priority: .userInitiated) {
            guard let resources = Bundle.main.resourceURL else {
                return Result(success: false, message: L("缺少直连工具，请重新安装 App"), details: "")
            }
            let process = Process()
            process.executableURL = resources.appendingPathComponent("direct/quaderno-direct")
            process.arguments = arguments
            process.environment = helperEnvironment().merging(extra) { _, new in new }
            // `.merged` keeps the legacy single-pipe JSON contract; only the deadline is new.
            let outcome = ProcessRunner.run(process, mode: .merged, timeout: 3600)
            let data = outcome.combined
            let output = String(decoding: data, as: UTF8.self)
            if !outcome.launchError.isEmpty {
                return Result(success: false, message: L("无法运行直连工具"), details: outcome.launchError)
            }
            if outcome.timedOut {
                return Result(success: false, message: L("直连失败，请检查设备连接"),
                              details: output + "\n[timeout 3600s]")
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return Result(success: outcome.exitCode == 0 && json?["ok"] as? Bool == true,
                          message: json?["message"] as? String ?? L("直连失败，请检查设备连接"),
                          details: output)
        }.value
    }
}
