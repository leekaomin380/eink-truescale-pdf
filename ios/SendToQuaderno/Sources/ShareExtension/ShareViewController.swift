import UIKit

/// 分享面板入口：接收文本或 URL，自动投递到 Mac 中继，显示结果后关闭。
final class ShareViewController: UIViewController {

    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 380, height: 180)
        view.backgroundColor = .systemBackground
        setupUI()
        Task { await autoSend() }
    }

    private func setupUI() {
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let icon = UIImageView(image: UIImage(systemName: "doc.badge.arrow.up"))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        statusLabel.text = "正在投递…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let done = UIButton(type: .system)
        done.setTitle("完成", for: .normal)
        done.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(done)
        spinner.startAnimating()

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private struct Input {
        var type: String
        var value: String
    }

    private func extractInput() async -> Input? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return nil
        }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier("public.url"),
                   let raw = try? await provider.loadItem(forTypeIdentifier: "public.url") {
                    if let u = raw as? URL { return Input(type: "url", value: u.absoluteString) }
                    if let s = raw as? String { return Input(type: "url", value: s) }
                    if let data = raw as? Data, let s = String(data: data, encoding: .utf8) {
                        return Input(type: "url", value: s)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier("public.plain-text"),
                   let raw = try? await provider.loadItem(forTypeIdentifier: "public.plain-text") {
                    if let text = raw as? String, !text.isEmpty {
                        return Input(type: "text", value: text)
                    }
                    if let data = raw as? Data,
                       let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        return Input(type: "text", value: text)
                    }
                }
            }
        }
        return nil
    }

    @MainActor
    private func autoSend() async {
        let config = RelayConfig.load()
        guard config.isConfigured else {
            finish("未配置服务器，请先打开 App 完成设置")
            return
        }
        guard let input = await extractInput() else {
            finish("没有可投递的文本或链接")
            return
        }

        let payload = input.type == "url"
            ? RelayClient.Payload(type: "url", content: nil, url: input.value, title: nil)
            : RelayClient.Payload(type: "text", content: input.value, url: nil, title: nil)

        do {
            let result = try await RelayClient.deliver(payload, config: config)
            HistoryStore.append(HistoryEntry(
                title: result.title ?? String(input.value.prefix(30)),
                kind: input.type,
                status: result.status ?? "?",
                pages: result.pages,
                timestamp: Date()))
            finish(result.displayText)
        } catch {
            finish("❌ \(error.localizedDescription)")
        }
    }

    @MainActor
    private func finish(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = text
    }
}
