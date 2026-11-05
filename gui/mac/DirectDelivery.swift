import Foundation

/// FIFO gate for App-side helper calls. Waiting happens *before* a process is started, so a
/// queued delivery neither hits the cross-process lock nor consumes its 3600 s hard deadline.
/// Device authentication has mutable session state; two helpers cannot safely overlap.
private actor DeliveryQueue {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var busy = false

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else { busy = false; return }
        waiters.removeFirst().resume()  // the slot passes directly to the next waiter
    }
}

/// Shared transport for manual App delivery and connection diagnostics.
/// Credentials remain outside the bundle; the helper verifies the paired device's key.
enum DirectDelivery {
    struct Result: Sendable {
        let success: Bool
        let message: String
        let details: String
    }

    private static let queue = DeliveryQueue()

    static func run(_ arguments: [String], environment extra: [String: String] = [:]) async -> Result {
        await queue.acquire()
        // defer covers cancellation / early exit too: a forgotten release would wedge the queue.
        defer { Task { await queue.release() } }
        return await Task.detached(priority: .userInitiated) {
            guard let resources = Bundle.main.resourceURL else {
                return Result(success: false, message: L("缺少直连工具，请重新安装 App"), details: "")
            }
            let process = Process()
            process.executableURL = resources.appendingPathComponent("direct/quaderno-direct")
            process.arguments = arguments
            process.environment = helperEnvironment().merging(extra) { _, new in new }
            // stderr is drained separately: a PyInstaller hint or DeprecationWarning must not
            // corrupt the JSON-over-stdout contract (CFR §3 P2-3).
            let outcome = ProcessRunner.run(process, mode: .separate, timeout: 3600)
            let output = String(decoding: outcome.stdout, as: UTF8.self)
            let stderr = String(decoding: outcome.stderr, as: UTF8.self)
            let details = [output, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            if !outcome.launchError.isEmpty {
                return Result(success: false, message: L("无法运行直连工具"), details: outcome.launchError)
            }
            if outcome.timedOut {
                return Result(success: false, message: L("直连失败，请检查设备连接"),
                              details: details + "\n[timeout 3600s]")
            }
            // The helper normally prints exactly one JSON object. A device file name may itself
            // contain a newline, so parse the whole stdout first; only if a helper prepends
            // progress lines do we fall back to the last standalone JSON line.
            var json = (try? JSONSerialization.jsonObject(with: outcome.stdout)) as? [String: Any]
            if json == nil {
                json = output.split(separator: "\n").reversed().compactMap { line -> [String: Any]? in
                    guard let bytes = String(line).data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                }.first
            }
            return Result(success: outcome.exitCode == 0 && json?["ok"] as? Bool == true,
                          message: json?["message"] as? String ?? L("直连失败，请检查设备连接"),
                          details: details)
        }.value
    }
}
