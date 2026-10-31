import SwiftUI
import AppKit

// 「设备文件」页面：浏览设备上的文件夹与文档，在设备上打开、下载到 Mac、移动、删除、新建文件夹。
// 投递从不删除或覆盖文件；这里的删除与移动只在用户明确操作并确认后执行。

struct DeviceEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let path: String
    let size: Int?
    let modified: Date?

    var isFolder: Bool { type == "folder" }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        type = json["type"] as? String ?? ""
        path = json["path"] as? String ?? ""
        // 设备把 file_size 作为字符串返回（实测），兼容数字。
        size = (json["size"] as? Int) ?? (json["size"] as? String).flatMap { Int($0) }
        modified = (json["modified"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

@MainActor
final class DeviceFilesModel: ObservableObject {
    static let shared = DeviceFilesModel()
    static let root = "Document"

    @Published private(set) var folderPath = DeviceFilesModel.root
    @Published private(set) var folderID = ""
    @Published private(set) var entries: [DeviceEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published var message = ""
    @Published var messageIsError = false

    var folders: [DeviceEntry] { entries.filter(\.isFolder) }
    var documents: [DeviceEntry] { entries.filter { !$0.isFolder } }
    var isRoot: Bool { folderPath == Self.root }

    /// 当前文件夹的各级路径，用于路径导航。
    var breadcrumb: [(name: String, path: String)] {
        let parts = folderPath.split(separator: "/").map(String.init)
        return parts.indices.map { (parts[$0], parts[...$0].joined(separator: "/")) }
    }

    /// keepMessage：操作成功后刷新时保留「已删除」等结果消息；普通浏览时清除旧消息。
    func load(_ path: String? = nil, keepMessage: Bool = false) async {
        loading = true
        defer { loading = false }
        let result = await DirectDelivery.run(["browse", "--path", path ?? folderPath])
        guard result.success, let listing = Self.browseResult(result.details) else {
            report(result.message, error: true)
            return
        }
        folderPath = listing.path
        folderID = listing.id
        entries = listing.entries
        loaded = true
        if !keepMessage { message = "" }
    }

    func goUp() async {
        guard !isRoot else { return }
        await load(folderPath.split(separator: "/").dropLast().joined(separator: "/"))
    }

    /// 执行一个改动设备的操作，成功后刷新当前文件夹。
    @discardableResult
    func perform(_ arguments: [String]) async -> Bool {
        let result = await DirectDelivery.run(arguments)
        report(result.message, error: !result.success)
        if result.success { await load(keepMessage: true) }
        return result.success
    }

    func report(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    /// 解析 browse 的 JSON 输出（也供移动面板浏览目标文件夹使用）。
    static func browseResult(_ output: String) -> (path: String, id: String, entries: [DeviceEntry])? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let folder = json["folder"] as? [String: Any],
              let path = folder["path"] as? String, let id = folder["id"] as? String,
              let items = json["entries"] as? [[String: Any]] else { return nil }
        return (path, id, items.compactMap(DeviceEntry.init))
    }
}

/// 「设备文件」页面：从工具栏打开，独立于四种投递方式。
struct DeviceFilesPage: View {
    var body: some View {
        HSplitView {
            DeviceFolderSidebar().frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
            DeviceDocumentsView().frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 左栏：路径与文件夹

struct DeviceFolderSidebar: View {
    @ObservedObject private var model = DeviceFilesModel.shared
    @ObservedObject private var monitor = QuickSendMonitor.shared
    @State private var newFolderName = ""
    @State private var askingFolderName = false
    @State private var folderToDelete: DeviceEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(part.name) { Task { await model.load(part.path) } }
                        .buttonStyle(.link)
                        .disabled(part.path == model.folderPath)
                }
                Spacer(minLength: 0)
                if model.loading { ProgressView().controlSize(.small) }
                Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("刷新"))
            }
            .lineLimit(1)

            List {
                if !model.isRoot {
                    Button { Task { await model.goUp() } } label: {
                        Label("上一级", systemImage: "arrow.turn.left.up")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.folders) { folder in
                    Button { Task { await model.load(folder.path) } } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("删除文件夹…", role: .destructive) { folderToDelete = folder }
                    }
                }
                if model.loaded && model.folders.isEmpty {
                    Text("没有子文件夹").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)

            HStack {
                Button("新建文件夹…", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    askingFolderName = true
                }
                .disabled(!model.loaded)
                Spacer()
            }

            if !model.loaded && !monitor.isReady {
                Text("连接设备并唤醒后点刷新。使用 Wi-Fi 时也可以直接刷新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("新建文件夹", isPresented: $askingFolderName) {
            TextField("名称", text: $newFolderName)
            Button("新建") {
                let name = newFolderName
                Task { await model.perform(["mkdir", "--id", model.folderID, "--name", name]) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在「\(model.folderPath)」中新建。")
        }
        .confirmationDialog(folderToDelete.map { L("删除文件夹「\($0.name)」？") } ?? "",
                            isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let folder = folderToDelete {
                    Task { await model.perform(["delete", "--id", folder.id, "--kind", "folder", "--name", folder.name]) }
                }
            }
        } message: {
            Text("文件夹中的文档和手写批注会一起删除，无法恢复。")
        }
        .task { if !model.loaded { await model.load() } }
    }
}

// MARK: - 右栏：文档列表与操作

struct DeviceDocumentsView: View {
    @ObservedObject private var model = DeviceFilesModel.shared
    @State private var selection: DeviceEntry.ID?
    @State private var documentToDelete: DeviceEntry?
    @State private var documentToMove: DeviceEntry?

    private var selected: DeviceEntry? { model.documents.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("在设备上打开", systemImage: "ipad") { if let doc = selected { open(doc) } }
                Button("下载…", systemImage: "arrow.down.circle") { if let doc = selected { download(doc) } }
                Button("移动…", systemImage: "folder") { documentToMove = selected }
                Spacer()
                Button("删除…", systemImage: "trash", role: .destructive) { documentToDelete = selected }
            }
            .disabled(selected == nil)
            .padding(12)
            Divider()

            Table(model.documents, selection: $selection) {
                TableColumn("名称") { doc in
                    Label(doc.name, systemImage: "doc.richtext").lineLimit(1).truncationMode(.middle).help(doc.name)
                }
                .width(min: 140, ideal: 200)
                TableColumn("大小") { doc in
                    Text(doc.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 64, max: 100)
                TableColumn("修改时间") { doc in
                    Text(doc.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 124, max: 180)
            }
            .contextMenu(forSelectionType: DeviceEntry.ID.self) { ids in
                if let doc = model.documents.first(where: { ids.contains($0.id) }) {
                    Button("在设备上打开") { open(doc) }
                    Button("下载…") { download(doc) }
                    Button("移动…") { documentToMove = doc }
                    Divider()
                    Button("删除…", role: .destructive) { documentToDelete = doc }
                }
            } primaryAction: { ids in
                if let doc = model.documents.first(where: { ids.contains($0.id) }) { open(doc) }
            }
            .overlay {
                if model.loaded && model.documents.isEmpty {
                    Text("这个文件夹里没有文档").foregroundStyle(.secondary)
                }
            }

            if !model.message.isEmpty {
                Divider()
                HStack {
                    Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.messageIsError ? .orange : .green)
                    Text(verbatim: model.message).lineLimit(2).textSelection(.enabled)
                    Spacer()
                }
                .font(.callout)
                .padding(10)
            }
        }
        .confirmationDialog(documentToDelete.map { L("删除「\($0.name)」？") } ?? "",
                            isPresented: Binding(get: { documentToDelete != nil }, set: { if !$0 { documentToDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let doc = documentToDelete {
                    selection = nil
                    Task { await model.perform(["delete", "--id", doc.id, "--kind", "document", "--name", doc.name]) }
                }
            }
        } message: {
            Text("文档上的手写批注会一起删除，无法恢复。")
        }
        .sheet(item: $documentToMove) { doc in MoveDocumentSheet(document: doc) }
    }

    private func open(_ doc: DeviceEntry) {
        Task {
            let result = await DirectDelivery.run(["open-doc", "--id", doc.id, "--name", doc.name])
            model.report(result.message, error: !result.success)
        }
    }

    private func download(_ doc: DeviceEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.name
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = await DirectDelivery.run(["download", "--id", doc.id, "--to", url.path])
            model.report(result.message, error: !result.success)
        }
    }
}

// MARK: - 移动：选择目标文件夹

struct MoveDocumentSheet: View {
    let document: DeviceEntry
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = DeviceFilesModel.shared
    @State private var path = DeviceFilesModel.root
    @State private var folderID = ""
    @State private var folders: [DeviceEntry] = []
    @State private var loading = false
    @State private var failure = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("移动「\(document.name)」").font(.headline).lineLimit(1)
            HStack {
                Button("上一级", systemImage: "arrow.turn.left.up") {
                    browse(path.split(separator: "/").dropLast().joined(separator: "/"))
                }
                .disabled(path == DeviceFilesModel.root)
                Text(verbatim: path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            List(folders) { folder in
                Button { browse(folder.path) } label: { Label(folder.name, systemImage: "folder") }
                    .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .frame(height: 220)
            if !failure.isEmpty { Text(verbatim: failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("移到这里") {
                    let target = folderID
                    dismiss()
                    Task { await model.perform(["move", "--id", document.id, "--to", target, "--name", document.name]) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderID.isEmpty || path == model.folderPath)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { browse(model.folderPath) }
    }

    private func browse(_ target: String) {
        loading = true
        Task {
            let result = await DirectDelivery.run(["browse", "--path", target])
            loading = false
            guard result.success, let listing = DeviceFilesModel.browseResult(result.details) else {
                failure = result.message
                return
            }
            failure = ""
            path = listing.path
            folderID = listing.id
            folders = listing.entries.filter(\.isFolder)
        }
    }
}
