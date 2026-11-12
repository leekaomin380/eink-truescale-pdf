import Foundation

func L(_ text: String) -> String { text }
func helperEnvironment() -> [String: String] { ProcessInfo.processInfo.environment }

@main
struct USBTransportTests {
    static func main() async throws {
        // Compile this executable in an isolated directory; use its actual resource lookup.
        let resources = Bundle.main.resourceURL!
        let directory = resources.appendingPathComponent("direct")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("quaderno-direct")
        let marker = resources.appendingPathComponent("started")
        let script = """
        #!/bin/sh
        echo "fixture-started:$1:marker=$MARKER" >&2
        if [ "$1" = "blocked" ]; then
            /usr/bin/touch "$MARKER"
            exec /bin/sleep 10
        fi
        echo '{"ok": true, "message": "connected"}'
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let operation = Task {
            await DirectDelivery.run(["blocked"], environment: ["MARKER": marker.path], timeout: 2)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: marker.path) {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                let result = await operation.value
                fatalError("helper did not launch: \(result.message) \(result.details)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = ProcessInfo.processInfo.systemUptime
        let background = await DirectDelivery.run(["usb-prepare"], timeout: 1, background: true)
        precondition(!background.success && background.message.contains("deferred"), "background recovery interfered with foreground operation")
        precondition(ProcessInfo.processInfo.systemUptime - start < 0.3, "background recovery queued behind operation")
        let failed = await operation.value
        precondition(!failed.success && failed.details.contains("timeout"), "hung helper did not time out")
        let next = await DirectDelivery.run(["check"], timeout: 2)
        precondition(next.success, "timeout left the shared delivery queue wedged")
        print("USB transport integration passed: busy queue skipped, hung process terminated, next operation succeeded")
    }
}
