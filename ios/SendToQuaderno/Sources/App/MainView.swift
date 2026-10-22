import SwiftUI
import UIKit

@main
struct SendToQuadernoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            MainView()
        }
    }
}

struct MainView: View {
    @State private var config = RelayConfig.load()
    @State private var history = HistoryStore.load()
    @State private var delivering = false
    @State private var lastResult: String?

    var body: some View {
        List {
            Section("投递") {
                Button {
                    sendClipboard()
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text(delivering ? "投递中…" : "投递剪贴板内容")
                        Spacer()
                    }
                }
                .disabled(delivering || !config.isConfigured)

                if !config.isConfigured {
                    Text("请先在下方完成设置")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let lastResult {
                    Text(lastResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("历史（最近 \(history.count) 条）") {
                if history.isEmpty {
                    Text("暂无投递记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).lineLimit(1)
                            HStack {
                                Text("\(e.kind == "url" ? "文章" : "文本") · \(e.timeText)")
                                if let p = e.pages { Text("· \(p) 页") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if !history.isEmpty {
                    Button("清空历史", role: .destructive) {
                        HistoryStore.clear()
                        history = []
                    }
                }
            }

            Section {
                SettingsFields(config: $config)
            } header: {
                Text("服务器设置")
            } footer: {
                Text("host 填 Mac 的局域网名（如 gaomingdemacbook-air.local）；token 见 Mac 上 ~/.config/p2q-relay/token。修改后自动保存。")
            }
        }
        .navigationTitle("投递到 Quaderno")
    }

    private func sendClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastResult = "剪贴板没有文本内容"
            return
        }
        delivering = true
        lastResult = nil
        Task {
            defer { delivering = false }
            do {
                let isURL = text.trimmingCharacters(in: .whitespaces)
                    .lowercased().hasPrefix("http")
                let payload = isURL
                    ? RelayClient.Payload(type: "url", content: nil, url: text, title: nil)
                    : RelayClient.Payload(type: "text", content: text, url: nil, title: nil)
                let result = try await RelayClient.deliver(payload, config: config)
                lastResult = result.displayText
                HistoryStore.append(HistoryEntry(
                    title: result.title ?? String(text.prefix(30)),
                    kind: isURL ? "url" : "text",
                    status: result.status ?? "?",
                    pages: result.pages,
                    timestamp: Date()))
                history = HistoryStore.load()
            } catch {
                lastResult = "❌ \(error.localizedDescription)"
            }
        }
    }
}

struct SettingsFields: View {
    @Binding var config: RelayConfig
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        TextField("Mac 地址（xxx.local 或 IP）", text: $config.host)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: config.host) { _ in config.save() }
        TextField("端口", value: $config.port, format: .number)
            .onChange(of: config.port) { _ in config.save() }
        SecureField("Token", text: $config.token)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: config.token) { _ in config.save() }
        Button {
            testConnection()
        } label: {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(testing ? "测试中…" : "测试连接")
            }
        }
        .disabled(testing || !config.isConfigured)
        if let testResult {
            Text(testResult).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            do {
                testResult = try await RelayClient.health(config: config)
                    ? "✅ 中继服务可达"
                    : "⚠️ 服务可达但响应异常，检查 token 与版本"
            } catch {
                testResult = "❌ 无法连接：\(error.localizedDescription)"
            }
        }
    }
}
