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
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return Result(success: process.terminationStatus == 0 && json?["ok"] as? Bool == true,
                              message: json?["message"] as? String ?? L("直连失败，请检查设备连接"),
                              details: output)
            } catch {
                return Result(success: false, message: L("无法运行直连工具"), details: error.localizedDescription)
            }
        }.value
    }
}
