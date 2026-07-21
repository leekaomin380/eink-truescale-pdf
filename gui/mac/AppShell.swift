import AppKit
import WebKit
import UniformTypeIdentifiers

let REPO = "/Users/km/projects/print-to-quaderno"
let SERVER_PY = REPO + "/gui/server.py"
let PYTHON = "/opt/homebrew/bin/python3"
let TIMEOUT: TimeInterval = 10

func pickFreePort() -> UInt16 {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return 8888 }
    defer { close(sock) }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) }
    }
    _ = withUnsafeMutablePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            withUnsafeMutablePointer(to: &len) { lenPtr in
                getsockname(sock, sockPtr, lenPtr)
            }
        }
    }
    return UInt16(bigEndian: addr.sin_port)
}

func killOrphans() {
    let r = Process()
    r.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    r.arguments = ["-f", "python3.*gui/server\\.py"]
    try? r.run()
    r.waitUntilExit()
}

class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var serverProcess: Process?
    var port: UInt16 = 0
    var pollTimer: Timer?
    var pollStartTime: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("AppShell: applicationDidFinishLaunching called")
        killOrphans()
        port = pickFreePort()
        NSLog("AppShell: picked port %d", port)

        guard FileManager.default.fileExists(atPath: REPO),
              FileManager.default.fileExists(atPath: SERVER_PY),
              FileManager.default.fileExists(atPath: PYTHON) else {
            showError("依赖缺失:\nREPO=\(REPO)\nSERVER_PY=\(SERVER_PY)\nPYTHON=\(PYTHON)")
            return
        }

        startServer()
        NSLog("AppShell: server started, starting poll timer")
        startPolling()
        NSLog("AppShell: applicationDidFinishLaunching completed")
    }

    func startServer() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: PYTHON)
        proc.arguments = ["-u", SERVER_PY, String(port)]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        proc.environment = env

        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            NSLog("AppShell: python terminated with status %d", status)
            if status != 0 {
                DispatchQueue.main.async {
                    self?.showError("Python 服务异常退出（状态码: \(status)）")
                }
            }
        }

        do {
            try proc.run()
            NSLog("AppShell: python PID=%d", proc.processIdentifier)
        } catch {
            showError("启动 Python 服务失败:\n\(error.localizedDescription)")
            return
        }
        serverProcess = proc
    }

    func startPolling() {
        pollStartTime = Date()
        NSLog("AppShell: starting poll timer")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            NSLog("AppShell: poll timer fired")
            self?.pollTick()
        }
        NSLog("AppShell: poll timer scheduled")
    }

    func pollTick() {
        guard let startTime = pollStartTime else { return }

        if Date().timeIntervalSince(startTime) > TIMEOUT {
            pollTimer?.invalidate()
            pollTimer = nil
            showError("后端服务启动超时（\(Int(TIMEOUT)) 秒）")
            return
        }

        if let proc = serverProcess, !proc.isRunning {
            pollTimer?.invalidate()
            pollTimer = nil
            showError("Python 服务已退出（状态码: \(proc.terminationStatus)）")
            return
        }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock >= 0 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(sock)
            if ok == 0 {
                NSLog("AppShell: server ready, launching web view")
                pollTimer?.invalidate()
                pollTimer = nil
                launchWebView()
                return
            }
        }
    }

    func launchWebView() {
        NSLog("AppShell: launchWebView called")
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.uiDelegate = self
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)")!))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "电子书转换 · Quaderno"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("AppShell: window created and shown")
    }

    func showError(_ msg: String) {
        let label = NSTextField(labelWithString: msg)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "启动失败"
        win.contentView = container
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        serverProcess?.terminate()
        serverProcess = nil
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "epub")!,
            UTType(filenameExtension: "fb2")!,
            UTType(filenameExtension: "html")!,
            UTType(filenameExtension: "md")!,
            UTType(filenameExtension: "markdown")!,
        ]
        panel.begin { result in
            if result == .OK, let url = panel.url {
                completionHandler([url])
            } else {
                completionHandler(nil)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
