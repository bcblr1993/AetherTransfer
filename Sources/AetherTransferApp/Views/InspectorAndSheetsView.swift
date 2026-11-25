import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Multi-Tab File Inspector View (Transmit 5 Parity)

private enum InspectorTab: String, CaseIterable, Identifiable {
    case general
    case permissions
    case cloud

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .general: return L10n.tr("常规", "General")
        case .permissions: return L10n.tr("权限", "Permissions")
        case .cloud: return L10n.tr("云端与链接", "Cloud / URLs")
        }
    }
}

struct FileInspectorView: View {
    let entry: FileEntry?
    var isRemoteOverride: Bool? = nil
    @ObservedObject var workspace: Workspace
    @State private var activeTab: InspectorTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("文件检查器", "File Inspector"))
                    .font(.headline)
                Spacer()
                Button {
                    workspace.showInspector = false
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.tr("关闭检查器", "Close Inspector"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if let item = entry {
                let isRemote = isRemoteOverride ?? workspace.isRemoteEntry(item)

                Picker("", selection: $activeTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.localizedTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

                Divider()

                FileInspectorDetailContent(
                    entry: item,
                    isRemote: isRemote,
                    activeTab: activeTab,
                    workspace: workspace
                )
                .id("\(isRemote ? "R" : "L"):\(item.id)")
            } else {
                Divider()
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(L10n.tr("选择一个文件以查看详细信息", "Select a file to inspect details"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct CustomMetadataRow: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

private enum PresignedExpiryOption: Int, CaseIterable, Identifiable {
    case min15 = 900
    case hour1 = 3600
    case hours24 = 86400
    case days7 = 604800

    var id: Int { rawValue }

    var localizedTitle: String {
        switch self {
        case .min15: return L10n.tr("15 分钟", "15 min")
        case .hour1: return L10n.tr("1 小时", "1 hour")
        case .hours24: return L10n.tr("24 小时", "24 hours")
        case .days7: return L10n.tr("7 天", "7 days")
        }
    }
}

private struct FileInspectorDetailContent: View {
    let entry: FileEntry
    let isRemote: Bool
    let activeTab: InspectorTab
    @ObservedObject var workspace: Workspace

    // General tab async state
    @State private var thumbnail: CGImage?
    @State private var folderSize: FolderSizeSummary?
    @State private var isCalculatingSize = false
    @State private var folderSizeError: String?
    @State private var folderSizeTask: Task<Void, Never>?

    @State private var checksums: FileChecksums?
    @State private var isCalculatingChecksums = false
    @State private var checksumError: String?
    @State private var checksumTask: Task<Void, Never>?

    // Cloud / URLs tab async state
    @State private var isLoadingMetadata = false
    @State private var isSavingMetadata = false
    @State private var metadataLoaded = false
    @State private var metadataNotice: String?
    @State private var metadataError: String?
    @State private var contentType = ""
    @State private var cacheControl = ""
    @State private var storageClass = ""
    @State private var acl = ""
    @State private var etag: String?
    @State private var customRows: [CustomMetadataRow] = []

    @State private var presignedExpiry: PresignedExpiryOption = .hour1
    @State private var presignedURLString: String?
    @State private var isGeneratingPresigned = false
    @State private var presignedError: String?

    @State private var loadMetadataTask: Task<Void, Never>?
    @State private var saveMetadataTask: Task<Void, Never>?
    @State private var presignedTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch activeTab {
                case .general:
                    generalTabBody
                case .permissions:
                    permissionsTabBody
                case .cloud:
                    cloudTabBody
                }
            }
            .padding(14)
        }
        .task(id: entry.id) {
            if !isRemote && !entry.isDirectory {
                thumbnail = await LaunchpadInspectorHelpers.loadImageThumbnail(
                    forFileAt: URL(fileURLWithPath: entry.path),
                    maxPixelSize: 180
                )
            }
        }
        .onDisappear {
            cancelAllTasks()
        }
    }

    private func cancelAllTasks() {
        folderSizeTask?.cancel()
        checksumTask?.cancel()
        loadMetadataTask?.cancel()
        saveMetadataTask?.cancel()
        presignedTask?.cancel()
    }

    // MARK: - General Tab
    @ViewBuilder
    private var generalTabBody: some View {
        VStack(spacing: 10) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 112, maxHeight: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            } else {
                Image(systemName: entry.isDirectory ? "folder.fill" : generalIconName)
                    .font(.system(size: 46))
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            }

            Text(entry.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)

        Divider()

        InspectorRow(title: L10n.tr("种类", "Kind"), value: entry.localizedKindDescription)

        if entry.isDirectory {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("大小", "Size"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let summary = folderSize {
                    Text(
                        L10n.tr(
                            "\(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))（\(summary.fileCount) 个文件，\(summary.folderCount) 个子文件夹）",
                            "\(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file)) (\(summary.fileCount) file(s), \(summary.folderCount) folder(s))"
                        )
                    )
                    .font(.caption)
                    .textSelection(.enabled)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        calculateFolderSize()
                    } label: {
                        Label(
                            isCalculatingSize
                                ? L10n.tr("正在计算…", "Calculating…")
                                : L10n.tr("计算文件夹大小", "Calculate Folder Size"),
                            systemImage: "scalemass"
                        )
                    }
                    .controlSize(.small)
                    .disabled(isCalculatingSize)

                    if isCalculatingSize {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("取消", "Cancel")) {
                            folderSizeTask?.cancel()
                            isCalculatingSize = false
                        }
                        .controlSize(.mini)
                    }
                }

                if let folderSizeError {
                    Text(folderSizeError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            InspectorRow(
                title: L10n.tr("大小", "Size"),
                value: "\(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)) (\(entry.size) \(L10n.tr("字节", "bytes")))"
            )
        }

        if let date = entry.modified {
            InspectorRow(title: L10n.tr("修改时间", "Modified"), value: date.formatted(date: .abbreviated, time: .standard))
        }

        InspectorRow(title: L10n.tr("完整路径", "Full Path"), value: entry.path)

        Divider()

        // Copy Server / Site Web URL section
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("链接地址", "URLs"))
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    let urlStr = workspace.inspectorServerURLString(for: entry, remote: isRemote)
                    copyToPasteboard(urlStr, notice: L10n.tr("已复制服务器 URL", "Copied Server URL"))
                } label: {
                    Label(
                        isRemote
                            ? L10n.tr("复制服务器 URL", "Copy Server URL")
                            : L10n.tr("复制文件 URL", "Copy File URL"),
                        systemImage: "link"
                    )
                }
                .controlSize(.small)
            }

            if let siteURL = workspace.siteWebURL(for: entry, remote: isRemote) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(siteURL.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button {
                            copyToPasteboard(siteURL.absoluteString, notice: L10n.tr("已复制站点 Web URL", "Copied Site Web URL"))
                        } label: {
                            Label(L10n.tr("复制站点 Web URL", "Copy Site Web URL"), systemImage: "globe")
                        }
                        .controlSize(.small)

                        Button {
                            NSWorkspace.shared.open(siteURL)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .controlSize(.small)
                        .help(L10n.tr("在浏览器中打开", "Open in Browser"))
                        .accessibilityLabel(L10n.tr("在浏览器中打开", "Open in Browser"))
                    }
                }
            }
        }

        // Local Checksum Calculator
        if !isRemote && !entry.isDirectory {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("文件校验和 (64 KiB 流式计算)", "Checksums (64 KiB Streaming)"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        calculateChecksums()
                    } label: {
                        Label(
                            isCalculatingChecksums
                                ? L10n.tr("正在计算…", "Calculating…")
                                : (checksums == nil
                                    ? L10n.tr("计算 SHA-256 / MD5 校验和", "Calculate Checksums")
                                    : L10n.tr("重新计算校验和", "Recalculate Checksums")),
                            systemImage: "number.square"
                        )
                    }
                    .controlSize(.small)
                    .disabled(isCalculatingChecksums)

                    if isCalculatingChecksums {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("取消", "Cancel")) {
                            checksumTask?.cancel()
                            isCalculatingChecksums = false
                        }
                        .controlSize(.mini)
                    }
                }

                if let checksums {
                    checksumRow(label: "SHA-256", digest: checksums.sha256)
                    checksumRow(label: "MD5", digest: checksums.md5)
                }

                if let checksumError {
                    Text(checksumError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
    }

    private func checksumRow(label: String, digest: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyToPasteboard(digest, notice: L10n.tr("已复制 \(label) 校验值", "Copied \(label) digest"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.tr("复制 \(label) 校验值", "Copy \(label) Digest"))
            }
            Text(digest)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var generalIconName: String {
        switch entry.fileExtension {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "photo.fill"
        case "mp4", "mov", "avi", "mkv": return "film.fill"
        case "mp3", "m4a", "flac", "wav": return "music.note"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "dmg": return "doc.zipper"
        case "swift", "c", "h", "cpp", "py", "sh", "js", "ts", "json", "xml", "html", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text.fill"
        }
    }

    private func calculateFolderSize() {
        folderSizeTask?.cancel()
        folderSizeError = nil
        isCalculatingSize = true
        let targetEntry = entry
        let remoteFlag = isRemote

        folderSizeTask = Task {
            do {
                let summary = try await workspace.calculateFolderSize(for: targetEntry, remote: remoteFlag)
                guard !Task.isCancelled else { return }
                folderSize = summary
                isCalculatingSize = false
            } catch is CancellationError {
                isCalculatingSize = false
            } catch {
                folderSizeError = error.localizedDescription
                isCalculatingSize = false
            }
        }
    }

    private func calculateChecksums() {
        checksumTask?.cancel()
        checksumError = nil
        isCalculatingChecksums = true
        let fileURL = URL(fileURLWithPath: entry.path)

        checksumTask = Task {
            do {
                let result = try await LaunchpadInspectorHelpers.computeChecksums(forFileAt: fileURL)
                guard !Task.isCancelled else { return }
                checksums = result
                isCalculatingChecksums = false
            } catch is CancellationError {
                isCalculatingChecksums = false
            } catch {
                checksumError = error.localizedDescription
                isCalculatingChecksums = false
            }
        }
    }

    // MARK: - Permissions Tab
    @ViewBuilder
    private var permissionsTabBody: some View {
        PermissionsEditor(entry: entry, workspace: workspace, isRemote: isRemote)
    }

    // MARK: - Cloud / URLs Tab
    @ViewBuilder
    private var cloudTabBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("访问链接", "Access URLs"))
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            let serverURL = workspace.inspectorServerURLString(for: entry, remote: isRemote)
            VStack(alignment: .leading, spacing: 4) {
                Text(isRemote ? L10n.tr("服务器 URL", "Server URL") : L10n.tr("本地文件 URL", "File URL"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(serverURL)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Button(L10n.tr("复制链接", "Copy URL")) {
                    copyToPasteboard(serverURL, notice: L10n.tr("已复制链接", "Copied URL"))
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)

            if let siteURL = workspace.siteWebURL(for: entry, remote: isRemote) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("站点公开 Web URL", "Public Site URL"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(siteURL.absoluteString)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button(L10n.tr("复制站点 URL", "Copy Site URL")) {
                            copyToPasteboard(siteURL.absoluteString, notice: L10n.tr("已复制站点 URL", "Copied Site URL"))
                        }
                        .controlSize(.small)
                        Button(L10n.tr("打开", "Open")) {
                            NSWorkspace.shared.open(siteURL)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)
            }
        }

        if isRemote && workspace.isConnectedToCloudObjectStore {
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.tr("云对象元数据", "Cloud Object Metadata"))
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isLoadingMetadata || isSavingMetadata {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("取消", "Cancel")) {
                            if isLoadingMetadata {
                                loadMetadataTask?.cancel()
                                isLoadingMetadata = false
                            }
                            if isSavingMetadata {
                                saveMetadataTask?.cancel()
                                isSavingMetadata = false
                            }
                        }
                        .controlSize(.mini)
                    }
                    Button(L10n.tr("加载元数据", "Load Metadata")) {
                        loadMetadata()
                    }
                    .controlSize(.small)
                    .disabled(isLoadingMetadata || entry.isDirectory)
                }

                if entry.isDirectory {
                    Text(L10n.tr("请选择具体对象文件以编辑云端元数据或生成临时签名链接。",
                                 "Select an object file to edit cloud metadata or generate a presigned URL."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        metadataField(title: "Content-Type", text: $contentType, prompt: "application/octet-stream")
                        metadataField(title: "Cache-Control", text: $cacheControl, prompt: "public, max-age=3600")
                        metadataField(title: L10n.tr("存储类型 (Storage Class)", "Storage Class"), text: $storageClass, prompt: "STANDARD")
                        metadataField(title: "ACL", text: $acl, prompt: "private / public-read")

                        if let etag, !etag.isEmpty {
                            InspectorRow(title: "ETag", value: etag)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.tr("自定义元数据 (x-amz-meta-*)", "Custom Metadata"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    customRows.append(CustomMetadataRow(key: "", value: ""))
                                } label: {
                                    Image(systemName: "plus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L10n.tr("添加自定义元数据", "Add Custom Metadata"))
                            }

                            ForEach($customRows) { $row in
                                HStack(spacing: 4) {
                                    TextField("key", text: $row.key)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                    TextField("value", text: $row.value)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                    Button {
                                        customRows.removeAll { $0.id == row.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(L10n.tr("删除此元数据行", "Remove Metadata Row"))
                                }
                            }
                        }

                        HStack {
                            if let metadataNotice {
                                Text(metadataNotice)
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Button(L10n.tr("保存元数据", "Save Metadata")) {
                                saveMetadata()
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .disabled(isSavingMetadata)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)

                    if let metadataError {
                        Text(metadataError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    Divider()

                    // Presigned URL Generator
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("临时签名链接 (Presigned URL)", "Presigned URL Generator"))
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        HStack {
                            Picker(L10n.tr("有效期", "Expires In"), selection: $presignedExpiry) {
                                ForEach(PresignedExpiryOption.allCases) { option in
                                    Text(option.localizedTitle).tag(option)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)

                            Button {
                                generatePresigned()
                            } label: {
                                Label(L10n.tr("生成链接", "Generate"), systemImage: "signature")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .disabled(isGeneratingPresigned)

                            if isGeneratingPresigned {
                                ProgressView().controlSize(.small)
                                Button(L10n.tr("取消", "Cancel")) {
                                    presignedTask?.cancel()
                                    isGeneratingPresigned = false
                                }
                                .controlSize(.mini)
                            }
                        }

                        if let presignedURLString {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(presignedURLString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                Button {
                                    copyToPasteboard(presignedURLString, notice: L10n.tr("已复制临时签名链接", "Copied presigned URL"))
                                } label: {
                                    Label(L10n.tr("复制临时链接", "Copy URL"), systemImage: "doc.on.doc")
                                }
                                .controlSize(.small)
                            }
                        }

                        if let presignedError {
                            Text(presignedError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.03))
                    .cornerRadius(8)
                }
            }
            .task(id: entry.id) {
                if !metadataLoaded && !entry.isDirectory {
                    loadMetadata()
                }
            }
            .onDisappear {
                loadMetadataTask?.cancel()
                saveMetadataTask?.cancel()
                presignedTask?.cancel()
            }
        } else {
            Divider()
            ContentUnavailableView {
                Label(L10n.tr("仅限云对象存储", "Cloud Object Stores Only"), systemImage: "cloud")
            } description: {
                Text(L10n.tr("连接 S3 / R2、Backblaze B2、Azure Blob 或 OpenStack Swift 远程文件后，可在此查看与编辑对象元数据及生成签名链接。",
                             "Connect to S3 / R2, Backblaze B2, Azure Blob, or OpenStack Swift to edit remote object metadata and generate presigned URLs."))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func metadataField(title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    private func loadMetadata() {
        loadMetadataTask?.cancel()
        metadataError = nil
        metadataNotice = nil
        isLoadingMetadata = true
        let remotePath = entry.path

        loadMetadataTask = Task {
            do {
                let meta = try await workspace.loadRemoteMetadata(for: remotePath)
                guard !Task.isCancelled else { return }
                contentType = meta.contentType ?? ""
                cacheControl = meta.cacheControl ?? ""
                storageClass = meta.storageClass ?? ""
                acl = meta.acl ?? ""
                etag = meta.etag
                customRows = meta.customMetadata
                    .sorted { $0.key < $1.key }
                    .map { CustomMetadataRow(key: $0.key, value: $0.value) }
                metadataLoaded = true
                isLoadingMetadata = false
            } catch is CancellationError {
                isLoadingMetadata = false
            } catch {
                metadataError = error.localizedDescription
                isLoadingMetadata = false
            }
        }
    }

    private func saveMetadata() {
        saveMetadataTask?.cancel()
        metadataError = nil
        metadataNotice = nil
        isSavingMetadata = true
        let remotePath = entry.path

        var customDict: [String: String] = [:]
        for row in customRows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                customDict[key] = row.value
            }
        }
        let updated = RemoteObjectMetadata(
            contentType: contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : contentType.trimmingCharacters(in: .whitespacesAndNewlines),
            cacheControl: cacheControl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cacheControl.trimmingCharacters(in: .whitespacesAndNewlines),
            storageClass: storageClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : storageClass.trimmingCharacters(in: .whitespacesAndNewlines),
            acl: acl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : acl.trimmingCharacters(in: .whitespacesAndNewlines),
            customMetadata: customDict,
            etag: etag,
            size: entry.size,
            modified: entry.modified
        )

        saveMetadataTask = Task {
            do {
                try await workspace.saveRemoteMetadata(updated, for: remotePath)
                guard !Task.isCancelled else { return }
                isSavingMetadata = false
                metadataNotice = L10n.tr("元数据已保存", "Metadata saved")
                workspace.flashNotice(L10n.tr("已更新对象元数据：\(entry.name)", "Updated object metadata for \(entry.name)"))
            } catch is CancellationError {
                isSavingMetadata = false
            } catch {
                metadataError = error.localizedDescription
                isSavingMetadata = false
            }
        }
    }

    private func generatePresigned() {
        presignedTask?.cancel()
        presignedError = nil
        isGeneratingPresigned = true
        let remotePath = entry.path
        let expires = presignedExpiry.rawValue

        presignedTask = Task {
            do {
                let url = try await workspace.generatePresignedURL(for: remotePath, expiresIn: expires)
                guard !Task.isCancelled else { return }
                presignedURLString = url.absoluteString
                isGeneratingPresigned = false
            } catch is CancellationError {
                isGeneratingPresigned = false
            } catch {
                presignedError = error.localizedDescription
                isGeneratingPresigned = false
            }
        }
    }

    private func copyToPasteboard(_ value: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        workspace.flashNotice(notice)
    }
}

struct InspectorRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permissions Editor (Bidirectional Triads + Octal + Recursive Apply)

struct PermissionsEditor: View {
    let entry: FileEntry
    @ObservedObject var workspace: Workspace
    let isRemote: Bool

    @State private var permissions: POSIXPermissions
    @State private var octalText: String
    @State private var octalInvalid = false
    @State private var isApplyingRecursive = false
    @State private var recursiveApplyTask: Task<Void, Never>?
    @State private var statusNotice: String?
    @State private var errorMessage: String?

    init(entry: FileEntry, workspace: Workspace, isRemote: Bool? = nil) {
        self.entry = entry
        self.workspace = workspace
        let resolvedRemote = isRemote ?? workspace.isRemoteEntry(entry)
        self.isRemote = resolvedRemote

        let initial: POSIXPermissions
        if !entry.permissions.isEmpty {
            initial = POSIXPermissions(fromModeString: entry.permissions)
        } else if !resolvedRemote, let localPerm = LaunchpadInspectorHelpers.localPOSIXPermissions(at: entry.path) {
            initial = localPerm
        } else {
            initial = entry.isDirectory
                ? (POSIXPermissions(fromOctalString: "0755") ?? POSIXPermissions())
                : (POSIXPermissions(fromOctalString: "0644") ?? POSIXPermissions())
        }
        self._permissions = State(initialValue: initial)
        self._octalText = State(initialValue: initial.octalString)
    }

    private var hasNativePOSIXMode: Bool {
        !entry.permissions.isEmpty || !isRemote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("权限设置 (POSIX)", "Permissions (POSIX)"))
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(permissions.modeString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !hasNativePOSIXMode {
                Text(L10n.tr("当前远程协议可能不支持 POSIX 权限位（应用修改时将尝试忽略或跳过）。",
                             "This remote protocol may not expose POSIX permission bits."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(L10n.tr("八进制权限：", "Octal Mode:"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("0755", text: $octalText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .frame(width: 72)
                    .onChange(of: octalText) { _, newValue in
                        if let parsed = LaunchpadInspectorHelpers.parseOctalPermissions(newValue) {
                            octalInvalid = false
                            if parsed != permissions {
                                permissions = parsed
                            }
                        } else {
                            octalInvalid = true
                        }
                    }

                if octalInvalid {
                    Text(L10n.tr("格式如 0755", "Use 0755 / 644"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            VStack(spacing: 6) {
                permissionRow(title: L10n.tr("所有者", "Owner"), triad: $permissions.owner)
                permissionRow(title: L10n.tr("用户组", "Group"), triad: $permissions.group)
                permissionRow(title: L10n.tr("其他人", "Others"), triad: $permissions.others)
            }
            .onChange(of: permissions) { _, updated in
                if LaunchpadInspectorHelpers.parseOctalPermissions(octalText) != updated {
                    octalText = updated.octalString
                    octalInvalid = false
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack {
                if let statusNotice {
                    Text(statusNotice)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(L10n.tr("应用修改", "Apply")) {
                    errorMessage = nil
                    workspace.applyPermissions(to: entry, permissions: permissions, remote: isRemote)
                    flashStatus(L10n.tr("已成功修改", "Applied"))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(octalInvalid || isApplyingRecursive)
            }

            if entry.isDirectory {
                Divider()

                HStack {
                    Button {
                        confirmAndApplyRecursively()
                    } label: {
                        Label(
                            L10n.tr("应用到包含的项目…", "Apply to Enclosed Items…"),
                            systemImage: "folder.badge.gearshape"
                        )
                    }
                    .controlSize(.small)
                    .disabled(octalInvalid || isApplyingRecursive)

                    if isApplyingRecursive {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("取消", "Cancel")) {
                            recursiveApplyTask?.cancel()
                            isApplyingRecursive = false
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
        .onDisappear {
            recursiveApplyTask?.cancel()
        }
    }

    private func permissionRow(title: String, triad: Binding<PermissionTriad>) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .frame(width: 50, alignment: .leading)
            Toggle(L10n.tr("读", "R"), isOn: triad.read).toggleStyle(.checkbox).font(.caption2)
            Toggle(L10n.tr("写", "W"), isOn: triad.write).toggleStyle(.checkbox).font(.caption2)
            Toggle(L10n.tr("执", "X"), isOn: triad.execute).toggleStyle(.checkbox).font(.caption2)
        }
    }

    private func confirmAndApplyRecursively() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr(
            "确认将权限 \(permissions.octalString) 应用到「\(entry.name)」内所有项目？",
            "Apply permissions \(permissions.octalString) to all enclosed items in \"\(entry.name)\"?"
        )
        alert.informativeText = L10n.tr(
            "此操作将递归修改该文件夹及所有子文件夹和文件的权限（\(permissions.modeString)），无法自动撤回。",
            "This will recursively set mode \(permissions.modeString) on this folder and every enclosed file and subfolder."
        )
        alert.addButton(withTitle: L10n.tr("应用到包含的项目", "Apply Recursively"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        recursiveApplyTask?.cancel()
        errorMessage = nil
        isApplyingRecursive = true
        let targetPermissions = permissions

        recursiveApplyTask = Task {
            do {
                let count = try await workspace.applyPermissionsRecursively(
                    to: entry,
                    permissions: targetPermissions,
                    remote: isRemote
                )
                guard !Task.isCancelled else { return }
                isApplyingRecursive = false
                flashStatus(L10n.tr("已递归更新 \(count) 项", "Updated \(count) item(s)"))
            } catch is CancellationError {
                isApplyingRecursive = false
                flashStatus(L10n.tr("已取消", "Cancelled"))
            } catch {
                errorMessage = error.localizedDescription
                isApplyingRecursive = false
            }
        }
    }

    private func flashStatus(_ text: String) {
        statusNotice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if statusNotice == text {
                statusNotice = nil
            }
        }
    }
}

// MARK: - Batch Rename Sheet

struct BatchRenameSheet: View {
    @ObservedObject var workspace: Workspace
    let items: [FileEntry]
    let isRemote: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var ruleType = 0
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var prefixText = ""
    @State private var suffixText = ""
    @State private var seqFormat = "Item_{N}"
    @State private var seqStart = 1
    @State private var seqPadding = 2

    var currentRule: RenameRule {
        switch ruleType {
        case 0: return .replace(find: findText, replaceWith: replaceText)
        case 1: return .addPrefix(prefixText)
        case 2: return .addSuffix(suffixText)
        case 3: return .sequence(format: seqFormat, start: seqStart, padding: seqPadding)
        default: return .replace(find: "", replaceWith: "")
        }
    }

    var plan: [RenameItemPlan] {
        let renamer = BatchRenamer(rule: currentRule)
        return renamer.plan(for: items.map(\.name))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(L10n.tr("批量重命名 \(items.count) 个项目", "Batch Rename \(items.count) Items"), systemImage: "pencil.and.list.clipboard")
                    .font(.headline)
                Spacer()
            }

            Picker(L10n.tr("规则类型", "Rule"), selection: $ruleType) {
                Text(L10n.tr("替换文本", "Replace Text")).tag(0)
                Text(L10n.tr("添加前缀", "Add Prefix")).tag(1)
                Text(L10n.tr("添加后缀", "Add Suffix")).tag(2)
                Text(L10n.tr("序列编号", "Sequence")).tag(3)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 8) {
                if ruleType == 0 {
                    HStack {
                        TextField(L10n.tr("查找文本", "Find"), text: $findText)
                        TextField(L10n.tr("替换为", "Replace with"), text: $replaceText)
                    }
                } else if ruleType == 1 {
                    TextField(L10n.tr("输入前缀字符串", "Enter prefix"), text: $prefixText)
                } else if ruleType == 2 {
                    TextField(L10n.tr("输入后缀字符串", "Enter suffix"), text: $suffixText)
                } else {
                    HStack {
                        TextField(L10n.tr("格式 (如 Photo_{N})", "Format (e.g. Photo_{N})"), text: $seqFormat)
                        TextField(L10n.tr("起始", "Start"), value: $seqStart, format: .number)
                            .frame(width: 60)
                        TextField(L10n.tr("位数", "Digits"), value: $seqPadding, format: .number)
                            .frame(width: 50)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(L10n.tr("效果预览：", "Preview:"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            List(plan) { item in
                HStack {
                    Text(item.originalName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.newName)
                        .font(.caption.bold())
                        .foregroundStyle(item.hasError ? .red : .primary)
                    Spacer()
                    if let err = item.errorDescription {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(height: 170)
            .border(Color.primary.opacity(0.08))

            HStack {
                Button(L10n.tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("执行重命名", "Rename")) {
                    workspace.executeBatchRename(plans: plan, remote: isRemote)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(plan.contains { $0.hasError } || plan.allSatisfy { $0.originalName == $0.newName })
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 440)
    }
}

// MARK: - Quick Text Editor Sheet

struct QuickEditorSheet: View {
    @ObservedObject var workspace: Workspace
    let context: EditingFileContext
    @State private var text: String
    @State private var originalContent: String
    @State private var showFindBar: Bool = false
    @State private var findQuery: String = ""
    @State private var replaceQuery: String = ""
    @State private var caseSensitive: Bool = false
    @State private var selectedEncoding: TextFileEncoding = .utf8
    @State private var showUnsavedCloseConfirm: Bool = false
    @FocusState private var isFindFieldFocused: Bool

    init(workspace: Workspace, context: EditingFileContext) {
        self.workspace = workspace
        self.context = context
        self._text = State(initialValue: context.content)
        self._originalContent = State(initialValue: context.content)
        self._selectedEncoding = State(initialValue: context.encoding)
    }

    private var isDirty: Bool {
        text != originalContent
    }

    private var compareOptions: String.CompareOptions {
        caseSensitive ? [] : [.caseInsensitive]
    }

    private var matchCount: Int {
        guard !findQuery.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: findQuery, options: compareOptions, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private var lineCount: Int {
        if text.isEmpty { return 0 }
        return text.components(separatedBy: "\n").count
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeaderBar

            if showFindBar {
                Divider()
                findAndReplaceBar
            }

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(10)

            Divider()

            editorFooterBar
        }
        .frame(minWidth: 740, minHeight: 540)
        .confirmationDialog(
            L10n.tr("是否放弃未保存的更改？", "Discard Unsaved Changes?"),
            isPresented: $showUnsavedCloseConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("保存并关闭", "Save & Close")) {
                workspace.v3SaveEditorContent(text, encoding: selectedEncoding)
            }
            Button(L10n.tr("放弃更改", "Discard Changes"), role: .destructive) {
                workspace.editingFile = nil
            }
            Button(L10n.tr("继续编辑", "Keep Editing"), role: .cancel) {}
        } message: {
            Text(L10n.tr("文件「\(context.name)」包含尚未保存的修改。", "\"\(context.name)\" has unsaved modifications."))
        }
        .onChange(of: selectedEncoding) { oldEncoding, newEncoding in
            guard !isDirty, let rawData = context.rawData else { return }
            do {
                let decoded = try TextFileHelper.decodeText(rawData, encoding: newEncoding)
                text = decoded
                originalContent = decoded
            } catch {
                selectedEncoding = oldEncoding
                workspace.error = error.localizedDescription
            }
        }
    }

    private var editorHeaderBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                if isDirty {
                    Text("•")
                        .font(.headline.bold())
                        .foregroundStyle(Color.orange)
                        .accessibilityLabel(L10n.tr("有未保存的更改", "Unsaved Changes"))
                }
                Label(context.name, systemImage: "doc.text.fill")
                    .font(.headline)
            }

            Text(context.remote ? L10n.tr("远程服务器文件", "Remote File") : L10n.tr("本地文件", "Local File"))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .cornerRadius(4)

            if isDirty {
                Text(L10n.tr("已修改", "Modified"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16))
                    .foregroundStyle(.orange)
                    .cornerRadius(4)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showFindBar.toggle()
                }
                if showFindBar {
                    DispatchQueue.main.async {
                        isFindFieldFocused = true
                    }
                }
            } label: {
                Label(L10n.tr("查找与替换", "Find & Replace"), systemImage: "magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: [.command])
            .help(L10n.tr("查找与替换 (⌘F)", "Find & Replace (⌘F)"))
            .accessibilityLabel(L10n.tr("查找与替换", "Find and Replace"))

            if context.isSaving {
                ProgressView().controlSize(.small)
            }

            Button(L10n.tr("关闭", "Close")) {
                attemptClose()
            }
            .keyboardShortcut(.cancelAction)

            Button(L10n.tr("保存更改", "Save Changes")) {
                workspace.v3SaveEditorContent(text, encoding: selectedEncoding)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(context.isSaving)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private var findAndReplaceBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("查找…", "Find…"), text: $findQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isFindFieldFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 170)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            HStack(spacing: 4) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("替换为…", "Replace…"), text: $replaceQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 160)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            Button {
                caseSensitive.toggle()
            } label: {
                Text("Aa")
                    .font(.caption.bold().monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(caseSensitive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                    )
                    .foregroundStyle(caseSensitive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("区分大小写", "Case Sensitive"))
            .accessibilityLabel(L10n.tr("区分大小写", "Case Sensitive"))

            Text(
                findQuery.isEmpty
                    ? L10n.tr("0 个匹配", "0 matches")
                    : L10n.tr("\(matchCount) 个匹配", "\(matchCount) match(es)")
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 74, alignment: .leading)

            Button(L10n.tr("替换", "Replace")) {
                replaceFirstMatch()
            }
            .controlSize(.small)
            .disabled(findQuery.isEmpty || matchCount == 0)

            Button(L10n.tr("全部替换", "Replace All")) {
                replaceAllMatches()
            }
            .controlSize(.small)
            .disabled(findQuery.isEmpty || matchCount == 0)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showFindBar = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("隐藏查找栏", "Hide Find Bar"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
    }

    private var editorFooterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(L10n.tr("字符编码：", "Encoding:"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker(L10n.tr("字符编码", "Encoding"), selection: $selectedEncoding) {
                    ForEach(TextFileEncoding.allCases) { encoding in
                        Text(encoding.localizedTitle).tag(encoding)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 195)
                .accessibilityLabel(L10n.tr("文件编码", "Text File Encoding"))
            }

            Spacer()

            Text(L10n.tr("\(lineCount) 行 · \(text.count) 个字符", "\(lineCount) lines · \(text.count) chars"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func attemptClose() {
        if isDirty {
            showUnsavedCloseConfirm = true
        } else {
            workspace.editingFile = nil
        }
    }

    private func replaceFirstMatch() {
        guard !findQuery.isEmpty,
              let range = text.range(of: findQuery, options: compareOptions) else { return }
        text.replaceSubrange(range, with: replaceQuery)
    }

    private func replaceAllMatches() {
        guard !findQuery.isEmpty else { return }
        text = text.replacingOccurrences(of: findQuery, with: replaceQuery, options: compareOptions)
    }
}

// MARK: - Built-in SSH Key Manager & Trusted Host Keys Sheet

private enum SSHManagerTab: String, CaseIterable, Identifiable {
    case localKeys
    case trustedHosts

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .localKeys: return L10n.tr("本机密钥对", "Local Key Pairs")
        case .trustedHosts: return L10n.tr("已信任主机指纹", "Trusted Host Keys")
        }
    }
}

struct SSHKeyManagerSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var activeTab: SSHManagerTab = .localKeys
    @State private var keys: [SSHKeyPairItem] = SSHKeyManager.listKeys()
    @State private var newKeyName = "id_ed25519_aether"
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var comment = "\(NSUserName())@AetherTransfer"
    @State private var passphrase = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(L10n.tr("SSH 密钥与主机指纹管理", "SSH Keys & Known Hosts"), systemImage: "key.horizontal.fill")
                    .font(.title3.bold())

                Spacer()

                Picker("", selection: $activeTab) {
                    ForEach(SSHManagerTab.allCases) { tab in
                        Text(tab.localizedTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                if activeTab == .localKeys {
                    Button(L10n.tr("刷新", "Refresh")) {
                        keys = SSHKeyManager.listKeys()
                    }
                }
            }
            .padding(18)
            .background(.ultraThinMaterial)

            Divider()

            if activeTab == .localKeys {
                localKeyPairsBody
            } else {
                trustedHostKeysBody
            }

            Divider()

            HStack {
                Text(
                    activeTab == .localKeys
                        ? L10n.tr("提示：生成的公钥将自动复制到剪贴板，可直接粘贴至服务器 ~/.ssh/authorized_keys",
                                  "Tip: Generated public keys are copied to clipboard for ~/.ssh/authorized_keys")
                        : L10n.tr("撤销信任后，下次连接该 SFTP 服务器将重新核对主机公钥指纹。",
                                  "Revoking a host key forces fingerprint verification on your next SFTP connection.")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("完成", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
        .frame(width: 720, height: 470)
    }

    private var localKeyPairsBody: some View {
        HSplitView {
            // Existing Keys List
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("本机已有密钥对 (\(keys.count))", "Existing Key Pairs (\(keys.count))"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                List(keys) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.name)
                                .font(.headline)
                            Spacer()
                            Text(item.keyType)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .cornerRadius(4)
                        }
                        Text(item.privateKeyPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.tr("复制公钥 (.pub)", "Copy Public Key")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.publicKeyContent, forType: .string)
                                workspace.flashNotice(L10n.tr("已复制公钥 \(item.name).pub", "Copied public key \(item.name).pub"))
                            }
                            .controlSize(.small)

                            Button(L10n.tr("在访达中显示", "Reveal in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.privateKeyPath)])
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minWidth: 320)

            // Generate New Key Form
            Form {
                Section(L10n.tr("生成新 SSH 密钥对", "Generate New SSH Key Pair")) {
                    TextField(L10n.tr("密钥文件名", "Key Filename"), text: $newKeyName)
                    Picker(L10n.tr("加密算法", "Algorithm"), selection: $algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases) { alg in
                            Text(alg.localizedDisplayName).tag(alg)
                        }
                    }
                    TextField(L10n.tr("备注 (Comment)", "Comment"), text: $comment)
                    SecureField(L10n.tr("私钥保护口令 (可选)", "Passphrase (Optional)"), text: $passphrase)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(L10n.tr("立即生成密钥对", "Generate Key Pair")) {
                        do {
                            errorMessage = nil
                            let created = try SSHKeyManager.generateKeyPair(
                                name: newKeyName,
                                algorithm: algorithm,
                                comment: comment,
                                passphrase: passphrase
                            )
                            keys = SSHKeyManager.listKeys()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(created.publicKeyContent, forType: .string)
                            workspace.flashNotice(L10n.tr("已生成 \(created.name) 并复制公钥至剪贴板", "Generated \(created.name) and copied public key"))
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300)
        }
    }

    @ViewBuilder
    private var trustedHostKeysBody: some View {
        let trustedProfiles = workspace.profilesWithTrustedHostKeys
        if trustedProfiles.isEmpty {
            ContentUnavailableView {
                Label(L10n.tr("暂无已信任的主机指纹", "No Trusted Host Keys"), systemImage: "lock.shield")
            } description: {
                Text(L10n.tr("首次连接 SFTP 服务器并确认信任其公钥指纹后，记录会显示在此处。",
                             "SFTP server host key fingerprints appear here after you trust them on first connect."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(trustedProfiles) { profile in
                let rawKey = profile.trustedHostKey ?? ""
                let fingerprint = RemoteClient.fingerprint(rawKey)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(profile.name.isEmpty ? profile.host : profile.name)
                            .font(.headline)
                        Text("\(profile.host):\(profile.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProtocolBadge(protocolKind: profile.protocolKind)
                    }

                    Text(fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)
                        .textSelection(.enabled)

                    HStack {
                        Button(L10n.tr("复制指纹", "Copy Fingerprint")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fingerprint, forType: .string)
                            workspace.flashNotice(L10n.tr("已复制主机指纹", "Copied host key fingerprint"))
                        }
                        .controlSize(.small)

                        Spacer()

                        Button(L10n.tr("撤销 / 忘记密钥", "Revoke / Forget Key"), role: .destructive) {
                            workspace.revokeTrustedHostKey(for: profile.id)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Zero-Knowledge Encrypted Bookmark Sync Sheet (Transmit Panic Sync Parity)

struct EncryptedSyncVaultSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var masterPassword = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("零知识加密书签保险箱 (.aethersync)", "Zero-Knowledge Encrypted Bookmark Vault"))
                        .font(.title3.bold())
                    Text(L10n.tr("采用 HKDF-SHA256 + AES-GCM-256 端到端加密，安全通过 iCloud Drive 或 Git 跨设备同步所有书签。",
                                 "End-to-end encrypted with HKDF-SHA256 + AES-GCM-256 for secure cross-Mac sync via iCloud Drive or Git."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                Section(L10n.tr("加密主密码 (Master Password)", "Master Encryption Password")) {
                    SecureField(L10n.tr("输入用于加解密保险箱的主密码", "Enter master password for vault encryption/decryption"), text: $masterPassword)
                }

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.green)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button(L10n.tr("关闭", "Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("从加密保险箱恢复…", "Import Encrypted Vault…")) {
                    importVault()
                }
                .disabled(masterPassword.isEmpty)

                Button(L10n.tr("导出加密保险箱 (.aethersync)…", "Export Encrypted Vault…")) {
                    exportVault()
                }
                .buttonStyle(.glassProminent)
                .disabled(masterPassword.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540, height: 300)
    }

    private func exportVault() {
        errorMessage = nil
        statusMessage = nil
        do {
            let encryptedData = try workspace.exportEncryptedVault(password: masterPassword)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "AetherBookmarks.aethersync"
            if panel.runModal() == .OK, let url = panel.url {
                try encryptedData.write(to: url, options: .atomic)
                statusMessage = L10n.tr("已成功加密并导出 \(workspace.profiles.count) 个服务器书签！",
                                        "Encrypted and exported \(workspace.profiles.count) server bookmark(s)!")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importVault() {
        errorMessage = nil
        statusMessage = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let count = try workspace.importEncryptedVault(data: data, password: masterPassword)
                statusMessage = L10n.tr("验证通过！已成功解密并合并 \(count) 个服务器书签。",
                                        "Verified! Decrypted and merged \(count) server bookmark(s).")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
