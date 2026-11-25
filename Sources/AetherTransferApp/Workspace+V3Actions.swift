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

    // Menu Bar / Toolbar Cross-Scene Requests & Display Mode Sync
    @Published var displayMode: BrowserDisplayMode = .list
    @Published var newFolderRequestCounter: Int = 0
    @Published var quickConnectRequestCounter: Int = 0
    @Published var viewOptionsRequestCounter: Int = 0
    @Published var externalEditRequestCounter: Int = 0

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

    // MARK: - Transfer Mode & Menu Requests

    func requestNewFolder() {
        v3UIStore.newFolderRequestCounter &+= 1
    }

    func requestQuickConnect() {
        v3UIStore.quickConnectRequestCounter &+= 1
    }

    func requestViewOptions() {
        v3UIStore.viewOptionsRequestCounter &+= 1
    }

    func requestExternalEdit() {
        v3UIStore.externalEditRequestCounter &+= 1
    }

    func effectiveTransferMode(for profile: ServerProfile) -> TransferMode {
        if v3UIStore.activeTransferMode != .automatic {
            return v3UIStore.activeTransferMode
        }
        if profile.defaultTransferMode != .automatic {
            return profile.defaultTransferMode
        }
        return FilesPreferencesStore.shared.transferMode
    }

    func setActiveTransferMode(_ mode: TransferMode) {
        v3UIStore.activeTransferMode = mode
        rulesAndTranscriptStore.appendTranscript(
            for: connectedProfile,
            category: .command,
            message: "Transfer mode set to \(mode.rawValue)"
        )
    }

    // MARK: - Raw Server Command Console

    func sendRawCommand(_ command: String) {
        let store = v3UIStore
        let containsControlBreaks = command.unicodeScalars.contains {
            $0 == "\n" || $0 == "\r" || $0 == "\0"
        }
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
        let targetPath = remotePath
        store.isRunningRawCommand = true
        rulesAndTranscriptStore.appendTranscript(
            for: client.profile,
            category: .command,
            message: "RAW> \(sanitizedCommand)"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.v3UIStore.isRunningRawCommand = false }

            do {
                let result = try await client.sendRawCommand(trimmed, path: targetPath)
                let sanitizedEntry = RawCommandResult(
                    command: TranscriptRedactor.sanitize(result.command),
                    output: TranscriptRedactor.sanitize(result.output),
                    succeeded: result.succeeded,
                    timestamp: result.timestamp
                )
                self.v3UIStore.rawCommandHistory.append(sanitizedEntry)
                let logOutput = sanitizedEntry.output.isEmpty
                    ? (sanitizedEntry.succeeded ? "OK" : "Command returned empty error")
                    : sanitizedEntry.output
                self.rulesAndTranscriptStore.appendTranscript(
                    for: client.profile,
                    category: sanitizedEntry.succeeded ? .response : .error,
                    message: logOutput
                )
            } catch {
                let sanitizedErr = TranscriptRedactor.sanitize(error.localizedDescription)
                let entry = RawCommandResult(
                    command: sanitizedCommand,
                    output: sanitizedErr,
                    succeeded: false
                )
                self.v3UIStore.rawCommandHistory.append(entry)
                self.rulesAndTranscriptStore.appendTranscript(
                    for: client.profile,
                    category: .error,
                    message: sanitizedErr
                )
            }
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

            do {
                var effectiveProfile = profile
                var effectiveCredentials = credentials
                let roleARN = profile.s3IAMRoleARN.trimmingCharacters(in: .whitespacesAndNewlines)
                if !roleARN.isEmpty {
                    let (stsProfile, stsCredentials, _) = try await AWSSTSClient().assumeRoleProfileAndCredentials(
                        profile: profile,
                        credentials: credentials
                    )
                    effectiveProfile = stsProfile
                    effectiveCredentials = stsCredentials
                }

                let buckets = try await S3Client(
                    profile: effectiveProfile,
                    credentials: effectiveCredentials
                ).listBuckets()
                self.v3UIStore.discoveredBuckets = buckets
                self.rulesAndTranscriptStore.appendTranscript(
                    for: profile,
                    category: .response,
                    message: "Listed \(buckets.count) S3 bucket(s)"
                )
            } catch is CancellationError {
                return
            } catch {
                let message = TranscriptRedactor.sanitize(error.localizedDescription)
                self.v3UIStore.bucketDiscoveryError = message
                self.rulesAndTranscriptStore.appendTranscript(
                    for: profile,
                    category: .error,
                    message: "S3 bucket discovery failed: \(message)"
                )
            }
        }
    }

    // MARK: - Server Import Wizard

    func loadImportFile(_ url: URL) {
        let store = v3UIStore
        store.importErrorMessage = nil
        store.importStatusMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try BookmarkImporter.importFromFile(at: url)
                }.value
                self.v3UIStore.importedItems = items
                self.v3UIStore.importStatusMessage = L10n.tr(
                    "已解析 \(items.count) 个服务器配置（\(url.lastPathComponent)）。",
                    "Loaded \(items.count) server profile(s) from \(url.lastPathComponent)."
                )
            } catch {
                self.v3UIStore.importedItems = []
                self.v3UIStore.importErrorMessage = error.localizedDescription
            }
        }
    }

    func loadLocalConfigsForImport() {
        let store = v3UIStore
        store.importErrorMessage = nil
        store.importStatusMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await Task.detached(priority: .userInitiated) {
                BookmarkImporter.importFromLocalConfigs()
            }.value

            self.v3UIStore.importedItems = items
            if items.isEmpty {
                self.v3UIStore.importStatusMessage = L10n.tr(
                    "未在 ~/.ssh/config 或 ~/.aws 中发现可导入配置。",
                    "No importable server entries found in ~/.ssh/config or ~/.aws."
                )
            } else {
                self.v3UIStore.importStatusMessage = L10n.tr(
                    "已从本机配置 (~/.ssh/config, ~/.aws) 扫描到 \(items.count) 个配置。",
                    "Scanned \(items.count) server entry(ies) from ~/.ssh/config and ~/.aws."
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
        connect(profile, credentials: credentials)
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

        rulesAndTranscriptStore.appendTranscript(
            for: profile,
            category: .connect,
            message: "MFA token submitted for IAM Role session (serial configured)"
        )
        connect(profile, credentials: creds, mfaTokenCode: cleaned)
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

    func extractLocalZip(_ entry: FileEntry, role: BrowserPaneRole = .leftLocal, layout: PaneLayoutController? = nil) {
        guard !entry.isDirectory, entry.fileExtension == "zip" else { return }
        let zipURL = URL(fileURLWithPath: entry.path)
        let destinationURL = zipURL.deletingLastPathComponent()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let extracted = try await ArchiveHelper.extractZip(at: zipURL, to: destinationURL)
                if let layout {
                    self.refreshPane(role: role, layout: layout)
                } else {
                    self.refreshLocal()
                }
                let notice = L10n.tr(
                    "已解压 \(entry.name)（\(extracted.count) 个顶层项目）",
                    "Extracted \(entry.name) (\(extracted.count) top-level item(s))"
                )
                self.rulesAndTranscriptStore.appendTranscript(for: nil, category: .command, message: notice)
                self.flashNotice(notice)
            } catch {
                self.error = L10n.tr(
                    "解压失败：\(error.localizedDescription)",
                    "Extraction failed: \(error.localizedDescription)"
                )
            }
        }
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
        if remote {
            download(entries, bypassingRules: true)
        } else {
            upload(entries, bypassingRules: true)
        }
    }

    // MARK: - Encoding-Aware Quick Editor Save

    func v3SaveEditorContent(_ newContent: String, encoding: TextFileEncoding) {
        guard var ctx = editingFile else { return }
        if ctx.remote, self.client == nil {
            self.error = L10n.tr(
                "连接已断开，无法保存远程文件。",
                "Disconnected from server; cannot save remote file."
            )
            ctx.isSaving = false
            self.editingFile = ctx
            return
        }

        let encodedData: Data
        do {
            encodedData = try TextFileHelper.encodeText(newContent, encoding: encoding)
        } catch {
            self.error = error.localizedDescription
            return
        }

        ctx.isSaving = true
        self.editingFile = ctx

        Task { @MainActor [weak self] in
            guard let self else { return }
            if ctx.remote {
                guard let client = self.client else {
                    self.error = L10n.tr(
                        "连接已断开，无法保存远程文件。",
                        "Disconnected from server; cannot save remote file."
                    )
                    ctx.isSaving = false
                    self.editingFile = ctx
                    return
                }
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
