import AppKit
import Combine
import Foundation
import SwiftUI
import AetherTransferCore

// MARK: - V3 UI Store Attached Weakly per Workspace

@MainActor
private final class TransmitV3UIRegistry {
    private final class WeakBox {
        weak var workspace: Workspace?
        let store: TransmitV3UIStore

        init(workspace: Workspace, store: TransmitV3UIStore) {
            self.workspace = workspace
            self.store = store
        }
    }

    static let shared = TransmitV3UIRegistry()
    private var entries: [ObjectIdentifier: WeakBox] = [:]

    func store(for workspace: Workspace) -> TransmitV3UIStore {
        let key = ObjectIdentifier(workspace)
        if let existing = entries[key], existing.workspace === workspace {
            return existing.store
        }
        entries = entries.filter { $0.value.workspace != nil }
        let store = TransmitV3UIStore(workspace: workspace)
        entries[key] = WeakBox(workspace: workspace, store: store)
        return store
    }
}

enum S3BucketPickerOrigin: Equatable, Sendable {
    case main
    case quickConnect
    case connectionSheet
}

@MainActor
final class TransmitV3UIStore: ObservableObject {
    private enum DefaultsKey {
        static let activeTransferMode = "com.aethernative.AetherTransfer.activeTransferMode"
        static let foldersFirst = "com.aethernative.AetherTransfer.foldersFirst"
    }

    weak var workspace: Workspace?

    // Raw Command Console
    @Published var showRawCommandSheet: Bool = false
    @Published var rawCommandHistory: [RawCommandResult] = []
    @Published var isRunningRawCommand: Bool = false

    // Server Import Wizard
    @Published var showImportServersSheet: Bool = false
    @Published var importedItems: [ImportedServerItem] = []
    @Published var importStatusMessage: String?
    @Published var importErrorMessage: String?

    // S3 Bucket Picker
    @Published var showBucketPickerSheet: Bool = false
    @Published var bucketPickerOrigin: S3BucketPickerOrigin = .main
    @Published var discoveredBuckets: [S3BucketInfo] = []
    @Published var isLoadingBuckets: Bool = false
    @Published var bucketDiscoveryError: String?
    var bucketPickerProfile: ServerProfile?
    var bucketPickerCredentials: Credentials?
    var onBucketSelected: ((String) -> Void)?

    // View Options Popover
    @Published var showViewOptionsPopover: Bool = false
    @Published var viewOptionsPaneRole: BrowserPaneRole?

    // S3 IAM Role MFA Prompt
    @Published var mfaChallengeProfile: ServerProfile?
    @Published var mfaChallengeCredentials: Credentials?

    // Persisted View & Transfer Mode Preferences
    @Published var activeTransferMode: TransferMode {
        didSet {
            UserDefaults.standard.set(activeTransferMode.rawValue, forKey: DefaultsKey.activeTransferMode)
            workspace?.objectWillChange.send()
        }
    }

    @Published var foldersFirst: Bool {
        didSet {
            UserDefaults.standard.set(foldersFirst, forKey: DefaultsKey.foldersFirst)
            workspace?.objectWillChange.send()
        }
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        let defaults = UserDefaults.standard
        if let rawMode = defaults.string(forKey: DefaultsKey.activeTransferMode),
           let mode = TransferMode(rawValue: rawMode) {
            self.activeTransferMode = mode
        } else {
            self.activeTransferMode = .automatic
        }
        if defaults.object(forKey: DefaultsKey.foldersFirst) != nil {
            self.foldersFirst = defaults.bool(forKey: DefaultsKey.foldersFirst)
        } else {
            self.foldersFirst = true
        }
    }
}

// MARK: - Workspace Extension for V3 Workflows

extension Workspace {
    var v3UIStore: TransmitV3UIStore {
        TransmitV3UIRegistry.shared.store(for: self)
    }

    // MARK: - Folders-First Display Sorting

    var v3SortedLocalFiles: [FileEntry] {
        FileEntry.sorted(
            localFiles,
            by: localSortField,
            ascending: localSortAscending,
            foldersFirst: v3UIStore.foldersFirst
        )
    }

    var v3SortedRemoteFiles: [FileEntry] {
        FileEntry.sorted(
            remoteFiles,
            by: remoteSortField,
            ascending: remoteSortAscending,
            foldersFirst: v3UIStore.foldersFirst
        )
    }

    func v3SortedSecondLocalFiles(layout: PaneLayoutController) -> [FileEntry] {
        FileEntry.sorted(
            layout.secondLocalFiles,
            by: layout.secondLocalSortField,
            ascending: layout.secondLocalSortAscending,
            foldersFirst: v3UIStore.foldersFirst
        )
    }

    func v3SortedSecondRemoteFiles(layout: PaneLayoutController) -> [FileEntry] {
        FileEntry.sorted(
            layout.secondRemoteFiles,
            by: layout.secondRemoteSortField,
            ascending: layout.secondRemoteSortAscending,
            foldersFirst: v3UIStore.foldersFirst
        )
    }

    // MARK: - Transfer Mode

    func setActiveTransferMode(_ mode: TransferMode) {
        v3UIStore.activeTransferMode = mode
        // Wave 3 v3-integrator: propagate activeTransferMode to TransferQueueManager / RemoteClient options
        rulesAndTranscriptStore.appendTranscript(
            for: connectedProfile,
            category: .command,
            message: "Transfer mode set to \(mode.rawValue)"
        )
    }

    // MARK: - Raw Server Command Console

    func sendRawCommand(_ command: String) {
        let store = v3UIStore
        let containsControlBreaks = command.contains("\n") || command.contains("\r") || command.contains("\0")
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !containsControlBreaks, !trimmed.isEmpty else {
            let errMsg = L10n.tr(
                "命令不能为空且不得包含换行符。",
                "Command must be non-empty and cannot contain newline characters."
            )
            store.rawCommandHistory.append(
                RawCommandResult(command: TranscriptRedactor.sanitize(trimmed), output: errMsg, succeeded: false)
            )
            return
        }

        guard let client else {
            let errMsg = L10n.tr("请先连接远程服务器。", "Connect to a remote server first.")
            store.rawCommandHistory.append(
                RawCommandResult(command: TranscriptRedactor.sanitize(trimmed), output: errMsg, succeeded: false)
            )
            return
        }

        let sanitizedCommand = TranscriptRedactor.sanitize(trimmed)
        store.isRunningRawCommand = true
        rulesAndTranscriptStore.appendTranscript(
            for: client.profile,
            category: .command,
            message: "RAW> \(sanitizedCommand)"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.v3UIStore.isRunningRawCommand = false }

            // Wave 3 v3-integrator: replace stub below with `let output = try await client.sendRawCommand(trimmed)`
            let resultMessage = L10n.tr(
                "已验证命令格式（\(client.profile.protocolKind.title)）。等待 Wave 3 RemoteClient.sendRawCommand 后端集成。",
                "Validated command for \(client.profile.protocolKind.title). Pending Wave 3 RemoteClient.sendRawCommand integration."
            )
            let entry = RawCommandResult(
                command: sanitizedCommand,
                output: TranscriptRedactor.sanitize(resultMessage),
                succeeded: false
            )
            self.v3UIStore.rawCommandHistory.append(entry)
            self.rulesAndTranscriptStore.appendTranscript(
                for: client.profile,
                category: .response,
                message: entry.output
            )
        }
    }

    // MARK: - S3 Bucket Discovery

    func browseS3Buckets(for profile: ServerProfile, credentials: Credentials) {
        browseS3Buckets(for: profile, credentials: credentials, origin: .main, onSelect: nil)
    }

    func browseS3Buckets(
        for profile: ServerProfile,
        credentials: Credentials,
        origin: S3BucketPickerOrigin,
        onSelect: ((String) -> Void)?
    ) {
        let store = v3UIStore
        store.bucketDiscoveryError = nil
        store.discoveredBuckets = []
        store.bucketPickerProfile = profile
        store.bucketPickerCredentials = credentials
        store.bucketPickerOrigin = origin
        if let onSelect {
            store.onBucketSelected = onSelect
        }

        do {
            try profile.validateForBucketDiscovery()
        } catch {
            self.error = error.localizedDescription
            store.bucketDiscoveryError = error.localizedDescription
            return
        }

        store.isLoadingBuckets = true
        store.showBucketPickerSheet = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.v3UIStore.isLoadingBuckets = false }
            // Wave 3 v3-integrator: wire to S3Client(profile: profile, credentials: credentials).listBuckets()
            self.v3UIStore.bucketDiscoveryError = L10n.tr(
                "存储桶列举接口已就绪，等待 Wave 3 S3Client.listBuckets() 后端集成。",
                "Bucket discovery UI ready; pending Wave 3 S3Client.listBuckets() integration."
            )
        }
    }

    // MARK: - Server Import Wizard

    func loadImportFile(_ url: URL) {
        let store = v3UIStore
        store.importErrorMessage = nil
        store.importStatusMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ext = url.pathExtension.lowercased()

            if ext == "json" {
                do {
                    let profiles = try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: url)
                        return try ServerProfile.importJSON(data)
                    }.value
                    let items = profiles.map {
                        ImportedServerItem(sourceFormat: "AetherTransfer JSON", profile: $0, hasPassword: false, selected: true)
                    }
                    self.v3UIStore.importedItems = items
                    self.v3UIStore.importStatusMessage = L10n.tr(
                        "已解析 \(items.count) 个服务器配置。",
                        "Loaded \(items.count) server profile(s)."
                    )
                } catch {
                    self.v3UIStore.importErrorMessage = error.localizedDescription
                }
                return
            }

            // Wave 3 v3-integrator: wire to BookmarkImporter.importFile(at: url) for FileZilla .xml, Cyberduck .duck, Transmit .exportedFavorites / .inetloc
            self.v3UIStore.importedItems = []
            self.v3UIStore.importErrorMessage = L10n.tr(
                "已读取文件「\(url.lastPathComponent)」；FileZilla / Cyberduck / Transmit 解析器将在 Wave 3 集成 BookmarkImporter 后启用。",
                "Selected \"\(url.lastPathComponent)\"; FileZilla / Cyberduck / Transmit parsing pending Wave 3 BookmarkImporter integration."
            )
        }
    }

    func loadLocalConfigsForImport() {
        let store = v3UIStore
        store.importErrorMessage = nil
        store.importStatusMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let sshItems = await Task.detached(priority: .userInitiated) { () -> [ImportedServerItem] in
                let hosts = SSHConfigParser.parseDefaultConfig()
                return hosts.map { entry in
                    ImportedServerItem(
                        sourceFormat: "SSH Config",
                        profile: entry.toServerProfile(),
                        hasPassword: false,
                        selected: true
                    )
                }
            }.value

            // Wave 3 v3-integrator: also merge ~/.aws/config & ~/.aws/credentials from BookmarkImporter.scanLocalConfigs()
            let awsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws", isDirectory: true)
            let hasAWSConfig = FileManager.default.fileExists(atPath: awsDir.appendingPathComponent("config").path)
                || FileManager.default.fileExists(atPath: awsDir.appendingPathComponent("credentials").path)

            self.v3UIStore.importedItems = sshItems
            if sshItems.isEmpty && !hasAWSConfig {
                self.v3UIStore.importStatusMessage = L10n.tr(
                    "未在 ~/.ssh/config 或 ~/.aws 中发现可导入配置。",
                    "No importable server entries found in ~/.ssh/config or ~/.aws."
                )
            } else if hasAWSConfig {
                self.v3UIStore.importStatusMessage = L10n.tr(
                    "已从 ~/.ssh/config 扫描到 \(sshItems.count) 个主机（~/.aws 解析将在 Wave 3 BookmarkImporter 集成后加入）。",
                    "Scanned \(sshItems.count) host(s) from ~/.ssh/config (~/.aws parsing pending Wave 3 BookmarkImporter)."
                )
            } else {
                self.v3UIStore.importStatusMessage = L10n.tr(
                    "已从 ~/.ssh/config 扫描到 \(sshItems.count) 个主机。",
                    "Scanned \(sshItems.count) host(s) from ~/.ssh/config."
                )
            }
        }
    }

    func commitImportedServers(_ items: [ImportedServerItem], importPasswords: Bool) {
        let chosen = items.filter(\.selected)
        guard !chosen.isEmpty else { return }

        var addedCount = 0
        var passwordCount = 0
        for item in chosen {
            var profile = item.profile
            let exists = profiles.contains {
                $0.protocolKind == profile.protocolKind &&
                $0.host == profile.host &&
                $0.port == profile.port &&
                $0.username == profile.username &&
                $0.name == profile.name
            }
            if exists { continue }

            profile.id = UUID()
            profiles.append(profile)
            addedCount += 1

            if importPasswords, item.hasPassword, let password = item.optionalPassword, !password.isEmpty {
                // Wave 3 v3-integrator: also store passphrase/sessionToken if BookmarkImporter supplies full Credentials
                do {
                    try CredentialStore.save(password, id: profile.id)
                    passwordCount += 1
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }

        if addedCount > 0 {
            persist()
            rulesAndTranscriptStore.appendTranscript(
                for: nil,
                category: .command,
                message: "Imported \(addedCount) server bookmark(s) (keychain passwords imported: \(passwordCount))"
            )
            flashNotice(
                L10n.tr(
                    "已导入 \(addedCount) 个服务器书签",
                    "Imported \(addedCount) server bookmark(s)"
                )
            )
        } else {
            flashNotice(L10n.tr("所选服务器已全部存在于书签中", "All selected servers already exist in bookmarks"))
        }
    }

    // MARK: - S3 IAM Role MFA Prompt

    func connectWithOptionalMFAPrompt(_ profile: ServerProfile, credentials: Credentials) {
        let roleARN = profile.s3IAMRoleARN.trimmingCharacters(in: .whitespacesAndNewlines)
        let mfaSerial = profile.s3MFASerial.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.protocolKind == .s3 && !roleARN.isEmpty && !mfaSerial.isEmpty {
            v3UIStore.mfaChallengeProfile = profile
            v3UIStore.mfaChallengeCredentials = credentials
            return
        }
        connectApplyingFolderLink(profile, credentials: credentials)
    }

    func submitMFAToken(_ token: String) {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 6, cleaned.allSatisfy(\.isNumber),
              let profile = v3UIStore.mfaChallengeProfile else {
            return
        }
        let creds = v3UIStore.mfaChallengeCredentials ?? loadCredentials(for: profile)
        v3UIStore.mfaChallengeProfile = nil
        v3UIStore.mfaChallengeCredentials = nil

        // Wave 3 v3-integrator: attach MFA TOTP token (`cleaned`) to STS AssumeRole credentials / S3Client
        rulesAndTranscriptStore.appendTranscript(
            for: profile,
            category: .connect,
            message: "MFA token submitted for IAM Role session (serial configured)"
        )
        connectApplyingFolderLink(profile, credentials: creds)
    }

    // MARK: - Browser Preview, Bypass Rules & Archive Actions

    func previewInBrowser(_ entry: FileEntry, remote: Bool) {
        if !remote {
            let fileURL = URL(fileURLWithPath: entry.path)
            NSWorkspace.shared.open(fileURL)
            return
        }

        guard let webURL = siteWebURL(for: entry, remote: true),
              let scheme = webURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            self.error = L10n.tr(
                "当前服务器未配置有效的站点 Web URL (siteURL)，无法在浏览器中预览。",
                "No valid Site Web URL is configured for this server bookmark."
            )
            return
        }
        NSWorkspace.shared.open(webURL)
    }

    func canPreviewInBrowser(_ entry: FileEntry, remote: Bool) -> Bool {
        if remote {
            return siteWebURL(for: entry, remote: true) != nil
        }
        guard !entry.isDirectory else { return false }
        let webAndImageExts: Set<String> = [
            "html", "htm", "xhtml", "svg", "pdf",
            "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"
        ]
        return webAndImageExts.contains(entry.fileExtension)
    }

    func extractLocalZip(_ entry: FileEntry) {
        guard !entry.isDirectory, entry.fileExtension == "zip" else { return }
        // Wave 3 v3-integrator: wire to ArchiveHelper.extractZip(at: URL(fileURLWithPath: entry.path), to: destinationURL)
        let notice = L10n.tr(
            "ZIP 解压等待 Wave 3 ArchiveHelper.extractZip 后端集成：\(entry.name)",
            "ZIP extraction pending Wave 3 ArchiveHelper.extractZip integration: \(entry.name)"
        )
        rulesAndTranscriptStore.appendTranscript(for: nil, category: .command, message: notice)
        flashNotice(notice)
    }

    func compressLocalEntries(_ entries: [FileEntry], role: BrowserPaneRole, layout: PaneLayoutController) {
        guard !role.isRemote, !entries.isEmpty else { return }
        let baseDirPath = currentPath(for: role, layout: layout)
        let baseDirURL = URL(fileURLWithPath: baseDirPath, isDirectory: true)
        let desiredName = entries.count == 1 ? "\(entries[0].name).zip" : "Archive.zip"
        let existingNames = (try? FileManager.default.contentsOfDirectory(atPath: baseDirPath)) ?? []
        let finalName = RemotePath.uniqueName(for: desiredName, existingNames: existingNames)
        let destinationZipURL = baseDirURL.appendingPathComponent(finalName)
        let sourceURLs = entries.map { URL(fileURLWithPath: $0.path) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ArchiveHelper.createZip(from: sourceURLs, destinationZipURL: destinationZipURL)
                }.value
                self.refreshPane(role: role, layout: layout)
                self.flashNotice(L10n.tr("已创建压缩包：\(finalName)", "Created archive: \(finalName)"))
            } catch {
                self.error = L10n.tr(
                    "压缩失败：\(error.localizedDescription)",
                    "Compression failed: \(error.localizedDescription)"
                )
            }
        }
    }

    func transferWithoutRules(_ entries: [FileEntry], remote: Bool) {
        guard !entries.isEmpty else { return }
        rulesAndTranscriptStore.appendTranscript(
            for: connectedProfile,
            category: .transfer,
            message: "Transfer Without Rules requested for \(entries.count) item(s) (remote=\(remote))"
        )
        // Wave 3 v3-integrator: pass `bypassingRules: true` to upload(_:bypassingRules:) / download(_:bypassingRules:)
        if remote {
            download(entries)
        } else {
            upload(entries)
        }
    }

    // MARK: - Encoding-Aware Quick Editor Save

    func v3SaveEditorContent(_ newContent: String, encoding: TextFileEncoding) {
        guard var ctx = editingFile else { return }
        guard let encodedData = newContent.data(using: encoding.stringEncoding) else {
            self.error = L10n.tr(
                "当前文本包含无法使用 \(encoding.localizedTitle) 编码保存的字符。",
                "Text contains characters that cannot be encoded as \(encoding.localizedTitle)."
            )
            return
        }

        if encoding == .utf8 {
            saveEditorContent(newContent)
            return
        }

        ctx.isSaving = true
        self.editingFile = ctx

        Task { @MainActor [weak self] in
            guard let self else { return }
            if ctx.remote, let client = self.client {
                let tempFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aether-save-enc-\(UUID().uuidString)-\(ctx.name)")
                defer { try? FileManager.default.removeItem(at: tempFile) }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try encodedData.write(to: tempFile, options: .atomic)
                    }.value
                    try await client.upload(tempFile, to: ctx.path, overwrite: true)
                    self.refreshRemote()
                    self.editingFile = nil
                    self.flashNotice(L10n.tr("已使用 \(encoding.localizedTitle) 保存远程文件", "Saved remote file (\(encoding.localizedTitle))"))
                } catch {
                    self.error = L10n.tr(
                        "保存远程文件失败：\(error.localizedDescription)",
                        "Failed to save remote file: \(error.localizedDescription)"
                    )
                    ctx.isSaving = false
                    self.editingFile = ctx
                }
            } else {
                let targetURL = URL(fileURLWithPath: ctx.path)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try encodedData.write(to: targetURL, options: .atomic)
                    }.value
                    self.refreshLocal()
                    self.editingFile = nil
                    self.flashNotice(L10n.tr("已使用 \(encoding.localizedTitle) 保存本地文件", "Saved local file (\(encoding.localizedTitle))"))
                } catch {
                    self.error = L10n.tr(
                        "保存本地文件失败：\(error.localizedDescription)",
                        "Failed to save local file: \(error.localizedDescription)"
                    )
                    ctx.isSaving = false
                    self.editingFile = ctx
                }
            }
        }
    }
}
