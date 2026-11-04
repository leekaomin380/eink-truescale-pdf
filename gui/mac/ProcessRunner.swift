import Foundation
import Darwin

/// How a child's output is captured. `.merged` keeps the legacy single-pipe behaviour
/// used by the JSON-over-stdout helpers; `.separate` is what a caller that parses stdout needs.
enum ProcessStreamMode {
    case none
    case separate
    case merged
}

struct ProcessOutcome {
    var stdout = Data()
    var stderr = Data()
    var combined = Data()
    var exitCode: Int32 = -1
    var timedOut = false
    var launchError = ""
}

/// Written on a background queue, read only after the DispatchGroup has completed.
private final class DataCollector: @unchecked Sendable {
    var data = Data()
}

/// Single choke point for every child process in the App.
/// Two invariants that a plain `waitUntilExit()` + `readDataToEndOfFile()` pairing violates:
///   1. Both pipes must be drained concurrently (a full ~64 KB buffer otherwise deadlocks).
///   2. Waiting must have a hard deadline (a child that never exits otherwise hangs the UI).
enum ProcessRunner {
    static func run(_ process: Process, mode: ProcessStreamMode, timeout: TimeInterval) -> ProcessOutcome {
        var outcome = ProcessOutcome()
        let outPipe = Pipe()
        let errPipe = Pipe()
        switch mode {
        case .none:
            break
        case .separate:
            process.standardOutput = outPipe
            process.standardError = errPipe
        case .merged:
            process.standardOutput = outPipe
            process.standardError = outPipe
        }
        do {
            try process.run()
        } catch {
            outcome.launchError = error.localizedDescription
            return outcome
        }

        let group = DispatchGroup()
        let outCollector = DataCollector()
        let errCollector = DataCollector()

        if mode != .none {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                outCollector.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if mode == .separate {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errCollector.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if mode == .none {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                group.leave()
            }
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            outcome.timedOut = true
            if process.isRunning { process.terminate() }   // SIGTERM
            _ = group.wait(timeout: .now() + 3)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 2)
        }
        if process.isRunning { process.waitUntilExit() }

        outcome.stdout = outCollector.data
        outcome.stderr = errCollector.data
        outcome.combined = outCollector.data
        outcome.exitCode = process.terminationStatus
        return outcome
    }
}
