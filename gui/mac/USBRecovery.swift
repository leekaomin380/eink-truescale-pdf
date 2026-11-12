import Foundation

/// Reconcile observed state rather than remembering commands sent to a serial pathname.
/// Time is monotonic so clock changes and sleep do not freeze retries.
struct USBRecoveryPolicy {
    private var identity: UInt64?
    private var nextAttempt: TimeInterval = 0
    private var attempts = 0
    private var inFlight = false

    mutating func observe(identity observed: UInt64?, ready: Bool, now: TimeInterval) -> Bool {
        if observed != identity {
            identity = observed
            attempts = 0
            nextAttempt = now + 3 // allow normal enumeration/discovery to settle
        }
        if ready {
            attempts = 0
            nextAttempt = now + 3
        }
        guard observed != nil, !ready, !inFlight, now >= nextAttempt else { return false }
        inFlight = true
        attempts += 1
        return true
    }

    mutating func finished(now: TimeInterval) {
        inFlight = false
        nextAttempt = now + min(30, 3 * pow(2, Double(min(max(attempts - 1, 0), 4))))
    }
}

enum USBRecoveryLog {
    /// Bounded, credential-free diagnostics. Helper preparation never reads pairing keys.
    static func record(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quaderno Converter/Direct")
        let path = directory.appendingPathComponent("usb-recovery.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            var data = (try? Data(contentsOf: path)) ?? Data()
            if data.count > 65_536 { data = Data(data.suffix(32_768)) }
            data.append(Data(line.utf8))
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            NSLog("USB recovery diagnostic write failed: %@", error.localizedDescription)
        }
    }
}
