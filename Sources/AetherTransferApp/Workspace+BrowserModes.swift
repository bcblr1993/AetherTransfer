import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Pane Display Mode & Appearance State

enum BrowserDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case list
    case columns
    case icons
    case gallery

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .list: return L10n.tr("列表", "List")
        case .columns: return L10n.tr("分栏", "Columns")
        case .icons: return L10n.tr("网格", "Grid")
        case .gallery: return L10n.tr("画廊", "Gallery")
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .icons: return "square.grid.2x2"
        case .gallery: return "rectangle.split.1x2"
        }
    }
}

enum WorkspaceFocusMode: String, CaseIterable, Identifiable, Sendable {
    case localOnly
    case dualPane
    case remoteOnly

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .localOnly: return L10n.tr("仅左侧", "Left Only")
        case .dualPane: return L10n.tr("双栏", "Dual Pane")
        case .remoteOnly: return L10n.tr("仅右侧", "Right Only")
        }
    }
}

enum LeftPaneSourceKind: String, CaseIterable, Identifiable, Sendable {
    case local
    case primaryRemote

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .local: return L10n.tr("本地", "Local")
        case .primaryRemote: return L10n.tr("主服务器", "Primary Remote")
        }
    }
}

enum RightPaneSourceKind: String, CaseIterable, Identifiable, Sendable {
    case primaryRemote
    case secondLocal
    case secondRemote

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .primaryRemote: return L10n.tr("主服务器", "Primary Remote")
        case .secondLocal: return L10n.tr("第二个本地", "Second Local")
        case .secondRemote: return L10n.tr("第二个服务器", "Second Remote")
        }
    }
}

enum BrowserPaneRole: Hashable, Sendable {
    case leftLocal
    case primaryRemote
    case secondLocal
    case secondRemote

    var isRemote: Bool {
        self == .primaryRemote || self == .secondRemote
    }
}

enum PaneSide: Hashable, Sendable {
    case left
    case right
}

@MainActor final class PaneAppearanceState: ObservableObject {
    private static let gridSizeKey = "com.aethernative.AetherTransfer.gridItemSize"
    private static let permissionsColumnKey = "com.aethernative.AetherTransfer.showPermissionsColumn"

    @Published var displayMode: BrowserDisplayMode = .list
    @Published var gridItemSize: Double {
        didSet {
            let clamped = min(160, max(72, gridItemSize))
            if clamped != gridItemSize {
                gridItemSize = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.gridSizeKey)
        }
    }
    @Published var showPermissionsColumn: Bool {
        didSet {
            UserDefaults.standard.set(showPermissionsColumn, forKey: Self.permissionsColumnKey)
        }
    }

    init() {
        let storedSize = UserDefaults.standard.double(forKey: Self.gridSizeKey)
        self.gridItemSize = (72...160).contains(storedSize) ? storedSize : 104
        if UserDefaults.standard.object(forKey: Self.permissionsColumnKey) != nil {
            self.showPermissionsColumn = UserDefaults.standard.bool(forKey: Self.permissionsColumnKey)
        } else {
            self.showPermissionsColumn = true
        }
    }

    func syncFromWorkspaceViewMode(_ viewMode: FileViewMode) {
        switch viewMode {
        case .list:
            if displayMode != .list { displayMode = .list }
        case .columns:
            if displayMode != .columns { displayMode = .columns }
        case .icons:
            if displayMode != .icons { displayMode = .icons }
        }
    }

    func applyDisplayMode(_ mode: BrowserDisplayMode, to workspace: Workspace) {
        displayMode = mode
        switch mode {
        case .list:
            if workspace.viewMode != .list { workspace.viewMode = .list }
        case .columns:
            if workspace.viewMode != .columns { workspace.viewMode = .columns }
        case .icons:
            if workspace.viewMode != .icons { workspace.viewMode = .icons }
        case .gallery:
            break
        }
    }
}

// MARK: - Thread-Safe Media, Thumbnail, Snippet, and POSIX Mode Cache

enum QuickPreviewContent: @unchecked Sendable {
    case image(NSImage)
    case text(String)
    case icon(NSImage, note: String?)
}

final class BrowserMediaCache: @unchecked Sendable {
    static let shared = BrowserMediaCache()

    private let thumbnailCache = NSCache<NSString, NSImage>()
    private let textCache = NSCache<NSString, NSString>()
    private let permissionCache = NSCache<NSString, NSString>()

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "icns"
    ]

    init() {
        thumbnailCache.countLimit = 400
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
        textCache.countLimit = 200
        permissionCache.countLimit = 1500
    }

    static func isImageExtension(_ ext: String) -> Bool {
        imageExtensions.contains(ext.lowercased())
    }

    func thumbnail(forLocalEntry entry: FileEntry, pixelSize: Int) async -> NSImage {
        let clampedPixels = max(64, min(640, pixelSize))
        let modStamp = Int64(entry.modified?.timeIntervalSince1970 ?? 0)
        let key = "thumb:\(entry.path)#\(clampedPixels)#\(modStamp)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        let cache = thumbnailCache
        let path = entry.path
        let isDir = entry.isDirectory
        let ext = entry.fileExtension

        return await Task.detached(priority: .utility) {
            let rendered: NSImage
            if !isDir, Self.isImageExtension(ext),
               let cgThumb = Self.createCGThumbnail(at: URL(fileURLWithPath: path), maxPixelSize: clampedPixels) {
                rendered = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
            } else {
                rendered = NSWorkspace.shared.icon(forFile: path)
            }
            cache.setObject(rendered, forKey: key)
            return rendered
        }.value
    }

    func iconForRemoteEntry(_ entry: FileEntry) -> NSImage {
        if entry.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        if !entry.fileExtension.isEmpty, let type = UTType(filenameExtension: entry.fileExtension) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    func formattedPermissions(for entry: FileEntry, remote: Bool) async -> String {
        if !entry.permissions.isEmpty {
            return entry.permissions
        }
        if remote {
            return "—"
        }
        let modStamp = Int64(entry.modified?.timeIntervalSince1970 ?? 0)
        let key = "perm:\(entry.path)#\(modStamp)" as NSString
        if let cached = permissionCache.object(forKey: key) {
            return cached as String
        }
        let cache = permissionCache
        let path = entry.path
        let isDir = entry.isDirectory
        let isLink = entry.isSymbolicLink

        return await Task.detached(priority: .utility) {
            let formatted = Self.readLocalModeString(path: path, isDirectory: isDir, isSymbolicLink: isLink)
            cache.setObject(formatted as NSString, forKey: key)
            return formatted
        }.value
    }

    func loadPreview(for entry: FileEntry, remote: Bool, client: RemoteClient?) async -> QuickPreviewContent {
        let modStamp = Int64(entry.modified?.timeIntervalSince1970 ?? 0)
        let scope = remote ? (client?.profile.id.uuidString ?? "remote") : "local"
        let thumbKey = "preview-img:\(scope):\(entry.path)#\(entry.size)#\(modStamp)" as NSString
        let textKey = "preview-txt:\(scope):\(entry.path)#\(entry.size)#\(modStamp)" as NSString

        if let img = thumbnailCache.object(forKey: thumbKey) {
            return .image(img)
        }
        if let txt = textCache.object(forKey: textKey) {
            return .text(txt as String)
        }

        if entry.isDirectory {
            let icon = remote ? iconForRemoteEntry(entry) : await thumbnail(forLocalEntry: entry, pixelSize: 256)
            return .icon(icon, note: nil)
        }

        if !remote {
            let url = URL(fileURLWithPath: entry.path)
            if Self.isImageExtension(entry.fileExtension), entry.size <= 40 * 1024 * 1024 {
                let thumb = await thumbnail(forLocalEntry: entry, pixelSize: 560)
                thumbnailCache.setObject(thumb, forKey: thumbKey)
                return .image(thumb)
            }
            if TextFileHelper.isTextFileName(entry.name) || entry.fileExtension.isEmpty {
                let textCacheRef = textCache
                let snippet: String? = await Task.detached(priority: .utility) {
                    guard let s = Self.readUTF8Snippet(at: url, maxBytes: 16 * 1024) else { return nil }
                    textCacheRef.setObject(s as NSString, forKey: textKey)
                    return s
                }.value
                if let snippet {
                    return .text(snippet)
                }
            }
            let icon = await thumbnail(forLocalEntry: entry, pixelSize: 256)
            return .icon(icon, note: nil)
        }

        // Remote preview (bounded sizes only, off main thread, cleaned up immediately)
        guard let client else {
            return .icon(iconForRemoteEntry(entry), note: nil)
        }
        if Self.isImageExtension(entry.fileExtension), entry.size > 0, entry.size <= 6 * 1024 * 1024 {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("aether-prev-\(UUID().uuidString)-\(entry.name)")
            do {
                try await client.download(entry.path, to: tempURL, overwrite: true)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try Task.checkCancellation()
                let thumbCacheRef = thumbnailCache
                let img: NSImage? = await Task.detached(priority: .utility) {
                    guard let cg = Self.createCGThumbnail(at: tempURL, maxPixelSize: 560) else { return nil }
                    let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    thumbCacheRef.setObject(nsImg, forKey: thumbKey)
                    return nsImg
                }.value
                if let img { return .image(img) }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } else if TextFileHelper.isTextFileName(entry.name), entry.size >= 0, entry.size <= 256 * 1024 {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("aether-prev-\(UUID().uuidString)-\(entry.name)")
            do {
                try await client.download(entry.path, to: tempURL, overwrite: true)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                try Task.checkCancellation()
                let textCacheRef = textCache
                let snippet: String? = await Task.detached(priority: .utility) {
                    guard let s = Self.readUTF8Snippet(at: tempURL, maxBytes: 16 * 1024) else { return nil }
                    textCacheRef.setObject(s as NSString, forKey: textKey)
                    return s
                }.value
                if let snippet { return .text(snippet) }
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        return .icon(iconForRemoteEntry(entry), note: nil)
    }

    private nonisolated static func createCGThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func readUTF8Snippet(at url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else {
            return ""
        }
        guard TextFileHelper.isProbablyTextData(data) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private nonisolated static func readLocalModeString(path: String, isDirectory: Bool, isSymbolicLink: Bool) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? Int else {
            return "—"
        }
        let prefix = isSymbolicLink ? "l" : (isDirectory ? "d" : "-")
        let octalStr = String(format: "%03o", mode & 0o777)
        let modeStr = POSIXPermissions(fromOctalString: octalStr)?.modeString ?? "---------"
        return prefix + modeStr
    }
}

// MARK: - Prompt & Conflict Helpers (isolated from private Workspace helpers)

enum BrowserPromptHelper {
    @MainActor
    static func askText(title: String, message: String = "", initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if !message.isEmpty {
            alert.informativeText = message
        }
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.tr("确定", "OK"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @MainActor
    static func resolveConflict(name: String, existing: [String], preference: DefaultConflictPreference) -> (String, Bool)? {
        guard existing.contains(name) else { return (name, false) }
        let resolution: ConflictResolution
        switch preference {
        case .overwrite: resolution = .overwrite
        case .merge: resolution = .merge
        case .keepBoth: resolution = .keepBoth
        case .skip: resolution = .skip
        case .ask:
            let alert = NSAlert()
            alert.messageText = L10n.tr("目标 \(name) 已存在", "Target \"\(name)\" already exists")
            alert.informativeText = L10n.tr("请选择如何处理此冲突：", "Choose how to resolve this conflict:")
            alert.addButton(withTitle: ConflictResolution.overwrite.localizedTitle)
            alert.addButton(withTitle: ConflictResolution.merge.localizedTitle)
            alert.addButton(withTitle: ConflictResolution.keepBoth.localizedTitle)
            alert.addButton(withTitle: ConflictResolution.skip.localizedTitle)
            switch alert.runModal() {
            case .alertFirstButtonReturn: resolution = .overwrite
            case .alertSecondButtonReturn: resolution = .merge
            case .alertThirdButtonReturn: resolution = .keepBoth
            default: resolution = .skip
            }
        }

        switch resolution {
        case .skip: return nil
        case .overwrite, .merge: return (name, true)
        case .keepBoth: return (RemotePath.uniqueName(for: name, existingNames: existing), false)
        }
    }
}

// MARK: - Dual-Pane Layout, Secondary Browsers, GoTo History & Custom Places Controller

@MainActor final class PaneLayoutController: ObservableObject {
    private static let localHistoryKey = "com.aethernative.AetherTransfer.goToLocalHistory"
    private static let remoteHistoryKey = "com.aethernative.AetherTransfer.goToRemoteHistory"

    @Published var focusMode: WorkspaceFocusMode = .dualPane
    @Published var leftPaneSource: LeftPaneSourceKind = .local
    @Published var rightPaneSource: RightPaneSourceKind = .primaryRemote
    @Published var activePaneSide: PaneSide = .left
    @Published var millerSelectedEntries: [BrowserPaneRole: FileEntry] = [:]
    @Published var secondRemoteEditingFile: EditingFileContext?

    // Go to Folder popovers (⇧⌘G)
    @Published var showLeftGoToFolder: Bool = false
    @Published var showRightGoToFolder: Bool = false
    @Published var localPathHistory: [String] = []
    @Published var remotePathHistory: [String] = []

    // Custom Places
    @Published var customPlaces: [CustomPlaceItem] = []
    private let placesStore = CustomPlacesStore()

    // Second Local Browser
    @Published var secondLocalPath: String
    @Published var secondLocalFiles: [FileEntry] = []
    @Published var secondLocalSelection: Set<String> = []
    @Published var loadingSecondLocal: Bool = false
    @Published var secondLocalHistory: NavigationHistory
    @Published var secondLocalSortField: FileSortField = .name
    @Published var secondLocalSortAscending: Bool = true
    private var secondLocalTask: Task<Void, Never>?
    private var secondLocalGeneration = UUID()

    // Second Remote Browser
    @Published var secondRemoteProfile: ServerProfile?
    @Published var secondRemotePath: String = "/"
    @Published var secondRemoteFiles: [FileEntry] = []
    @Published var secondRemoteSelection: Set<String> = []
    @Published var loadingSecondRemote: Bool = false
    @Published var connectingSecondRemote: Bool = false
    @Published var secondRemoteHistory: NavigationHistory = NavigationHistory(initialPath: "/")
    @Published var secondRemoteSortField: FileSortField = .name
    @Published var secondRemoteSortAscending: Bool = true
    @Published var secondRemoteHostChallenge: Workspace.HostChallenge?
    @Published var secondRemotePasswordPrompt: ServerProfile?
    private var secondRemoteCredentials = Credentials()
    private var secondRemoteTask: Task<Void, Never>?
    private var secondRemoteGeneration = UUID()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop")
        let initialSecondLocal = FileManager.default.fileExists(atPath: desktop.path) ? desktop.path : home.path
        self.secondLocalPath = initialSecondLocal
        self.secondLocalHistory = NavigationHistory(initialPath: initialSecondLocal)

        self.localPathHistory = UserDefaults.standard.stringArray(forKey: Self.localHistoryKey) ?? [home.path, desktop.path]
        self.remotePathHistory = UserDefaults.standard.stringArray(forKey: Self.remoteHistoryKey) ?? ["/"]
        self.customPlaces = (try? placesStore.load()) ?? []
    }

    var sortedSecondLocalFiles: [FileEntry] {
        FileEntry.sorted(secondLocalFiles, by: secondLocalSortField, ascending: secondLocalSortAscending, foldersFirst: true)
    }

    var sortedSecondRemoteFiles: [FileEntry] {
        FileEntry.sorted(secondRemoteFiles, by: secondRemoteSortField, ascending: secondRemoteSortAscending, foldersFirst: true)
    }

    func secondRemoteClient(speedLimit: Int64?) -> RemoteClient? {
        secondRemoteProfile.map {
            RemoteClient(profile: $0, credentials: secondRemoteCredentials, speedLimitBytesPerSec: speedLimit)
        }
    }

    // MARK: - Path History
    func recordPathVisit(_ path: String, remote: Bool) {
        let normalized = RemotePath.normalize(path)
        if remote {
            var list = remotePathHistory.filter { $0 != normalized }
            list.insert(normalized, at: 0)
            if list.count > 12 { list.removeLast(list.count - 12) }
            remotePathHistory = list
            UserDefaults.standard.set(list, forKey: Self.remoteHistoryKey)
        } else {
            var list = localPathHistory.filter { $0 != normalized }
            list.insert(normalized, at: 0)
            if list.count > 12 { list.removeLast(list.count - 12) }
            localPathHistory = list
            UserDefaults.standard.set(list, forKey: Self.localHistoryKey)
        }
    }

    // MARK: - Custom Places Management
    func pinCustomPlace(name: String, path: String, isRemote: Bool, profileId: UUID?, systemImage: String? = nil) {
        let normalized = RemotePath.normalize(path)
        let cleanName = name.isEmpty ? ((normalized as NSString).lastPathComponent.isEmpty ? "/" : (normalized as NSString).lastPathComponent) : name
        guard !customPlaces.contains(where: { $0.path == normalized && $0.isRemote == isRemote && $0.profileId == profileId }) else {
            return
        }
        let icon = systemImage ?? (isRemote ? "network" : "folder.fill")
        customPlaces.append(CustomPlaceItem(name: cleanName, path: normalized, isRemote: isRemote, profileId: profileId, systemImage: icon))
        persistCustomPlaces()
    }

    func unpinCustomPlace(_ place: CustomPlaceItem) {
        customPlaces.removeAll { $0.id == place.id }
        persistCustomPlaces()
    }

    func pinDroppedItems(_ items: [DroppedItem], connectedProfileId: UUID?, secondRemoteProfileId: UUID?) -> Bool {
        var added = false
        for item in items {
            switch item {
            case .app(let dragged) where dragged.isDirectory:
                let profileId = dragged.remote ? (dragged.profileID ?? connectedProfileId ?? secondRemoteProfileId) : nil
                pinCustomPlace(name: dragged.name, path: dragged.path, isRemote: dragged.remote, profileId: profileId)
                added = true
            case .file(let url) where url.isFileURL:
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    pinCustomPlace(name: url.lastPathComponent, path: url.path, isRemote: false, profileId: nil)
                    added = true
                }
            default:
                continue
            }
        }
        return added
    }

    private func persistCustomPlaces() {
        try? placesStore.save(customPlaces)
    }

    // MARK: - Second Local Navigation
    func activateSecondLocal(showHidden: Bool) {
        if secondLocalFiles.isEmpty && !loadingSecondLocal {
            refreshSecondLocal(showHidden: showHidden)
        }
    }

    func navigateSecondLocal(to path: String, showHidden: Bool) {
        secondLocalHistory.navigateTo(path)
        secondLocalPath = secondLocalHistory.currentPath
        recordPathVisit(secondLocalPath, remote: false)
        refreshSecondLocal(showHidden: showHidden)
    }

    func refreshSecondLocal(showHidden: Bool, onError: ((String) -> Void)? = nil) {
        secondLocalTask?.cancel()
        let path = secondLocalPath
        let generation = UUID()
        secondLocalGeneration = generation
        loadingSecondLocal = true
        secondLocalTask = Task {
            do {
                let files = try await Task.detached {
                    try LocalFiles.list(URL(fileURLWithPath: path), showHidden: showHidden)
                }.value
                guard generation == secondLocalGeneration else { return }
                secondLocalFiles = files
                secondLocalSelection = []
            } catch {
                if generation == secondLocalGeneration {
                    onError?(error.localizedDescription)
                }
            }
            if generation == secondLocalGeneration {
                loadingSecondLocal = false
            }
        }
    }

    func goBackSecondLocal(showHidden: Bool) {
        if secondLocalHistory.goBack() {
            secondLocalPath = secondLocalHistory.currentPath
            refreshSecondLocal(showHidden: showHidden)
        }
    }

    func goForwardSecondLocal(showHidden: Bool) {
        if secondLocalHistory.goForward() {
            secondLocalPath = secondLocalHistory.currentPath
            refreshSecondLocal(showHidden: showHidden)
        }
    }

    func parentSecondLocal(showHidden: Bool) {
        let parent = URL(fileURLWithPath: secondLocalPath).deletingLastPathComponent().path
        navigateSecondLocal(to: parent, showHidden: showHidden)
    }

    func chooseSecondLocal(showHidden: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            navigateSecondLocal(to: url.path, showHidden: showHidden)
        }
    }

    func toggleSecondLocalSort(_ field: FileSortField) {
        if secondLocalSortField == field {
            secondLocalSortAscending.toggle()
        } else {
            secondLocalSortField = field
            secondLocalSortAscending = true
        }
    }

    // MARK: - Second Remote Navigation & Connection
    func connectSecondRemoteSaved(_ profile: ServerProfile, workspace: Workspace) {
        let saved = workspace.loadCredentials(for: profile)
        if profile.needsPasswordPrompt(for: saved) {
            secondRemotePasswordPrompt = profile
            return
        }
        connectSecondRemote(profile, credentials: saved, workspace: workspace)
    }

    func connectSecondRemoteWithPassword(_ profile: ServerProfile, password: String, remember: Bool, workspace: Workspace) {
        secondRemotePasswordPrompt = nil
        var creds = workspace.loadCredentials(for: profile)
        creds.password = password
        if remember {
            do { try CredentialStore.save(password, id: profile.id) }
            catch { workspace.error = error.localizedDescription }
        }
        connectSecondRemote(profile, credentials: creds, workspace: workspace)
    }

    func connectSecondRemote(_ profile: ServerProfile, credentials: Credentials, workspace: Workspace) {
        secondRemoteTask?.cancel()
        secondRemoteProfile = profile
        secondRemoteCredentials = credentials
        secondRemotePath = RemotePath.normalize(profile.initialPath)
        secondRemoteHistory = NavigationHistory(initialPath: secondRemotePath)
        secondRemoteFiles = []
        connectingSecondRemote = true
        refreshSecondRemote(workspace: workspace)
    }

    func approveSecondRemoteHostKey(workspace: Workspace) {
        guard let challenge = secondRemoteHostChallenge else { return }
        var profile = challenge.profile
        profile.trustedHostKey = challenge.key
        if let index = workspace.profiles.firstIndex(where: { $0.id == profile.id }) {
            workspace.profiles[index] = profile
            workspace.persist()
        }
        secondRemoteHostChallenge = nil
        connectSecondRemote(profile, credentials: secondRemoteCredentials, workspace: workspace)
    }

    func disconnectSecondRemote() {
        secondRemoteTask?.cancel()
        secondRemoteGeneration = UUID()
        secondRemoteProfile = nil
        secondRemoteFiles = []
        secondRemoteSelection = []
        secondRemoteEditingFile = nil
        millerSelectedEntries.removeValue(forKey: .secondRemote)
        connectingSecondRemote = false
        loadingSecondRemote = false
    }

    func navigateSecondRemote(to path: String, workspace: Workspace) {
        secondRemoteHistory.navigateTo(path)
        secondRemotePath = secondRemoteHistory.currentPath
        recordPathVisit(secondRemotePath, remote: true)
        refreshSecondRemote(workspace: workspace)
    }

    func refreshSecondRemote(workspace: Workspace) {
        guard let client = secondRemoteClient(speedLimit: workspace.speedLimit) else { return }
        secondRemoteTask?.cancel()
        let path = secondRemotePath
        let generation = UUID()
        secondRemoteGeneration = generation
        loadingSecondRemote = true
        secondRemoteTask = Task {
            do {
                let files = try await client.list(path)
                guard generation == secondRemoteGeneration else { return }
                secondRemoteFiles = files
                secondRemoteSelection = []
            } catch let failure as TransferError {
                guard generation == secondRemoteGeneration else { return }
                if case .hostKeyRequired(let key, let changed) = failure, !changed {
                    secondRemoteHostChallenge = Workspace.HostChallenge(key: key, profile: client.profile)
                } else {
                    workspace.error = failure.localizedDescription
                }
            } catch is CancellationError {
            } catch {
                if generation == secondRemoteGeneration {
                    workspace.error = error.localizedDescription
                }
            }
            if generation == secondRemoteGeneration {
                loadingSecondRemote = false
                connectingSecondRemote = false
            }
        }
    }

    func goBackSecondRemote(workspace: Workspace) {
        if secondRemoteHistory.goBack() {
            secondRemotePath = secondRemoteHistory.currentPath
            refreshSecondRemote(workspace: workspace)
        }
    }

    func goForwardSecondRemote(workspace: Workspace) {
        if secondRemoteHistory.goForward() {
            secondRemotePath = secondRemoteHistory.currentPath
            refreshSecondRemote(workspace: workspace)
        }
    }

    func parentSecondRemote(workspace: Workspace) {
        navigateSecondRemote(to: RemotePath.parent(secondRemotePath), workspace: workspace)
    }

    func toggleSecondRemoteSort(_ field: FileSortField) {
        if secondRemoteSortField == field {
            secondRemoteSortAscending.toggle()
        } else {
            secondRemoteSortField = field
            secondRemoteSortAscending = true
        }
    }

    func saveSecondRemoteEditorContent(_ newContent: String, workspace: Workspace) {
        guard var ctx = secondRemoteEditingFile,
              let secondClient = secondRemoteClient(speedLimit: workspace.speedLimit) else { return }
        ctx.isSaving = true
        secondRemoteEditingFile = ctx
        let targetPath = ctx.path
        let fileName = ctx.name
        Task { [weak self] in
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("aether-save2-\(UUID().uuidString)-\(fileName)")
            defer { try? FileManager.default.removeItem(at: tempFile) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try newContent.write(to: tempFile, atomically: true, encoding: .utf8)
                }.value
                try await secondClient.upload(tempFile, to: targetPath, overwrite: true)
                self?.refreshSecondRemote(workspace: workspace)
                self?.secondRemoteEditingFile = nil
                workspace.flashNotice(L10n.tr("已保存远程文件：\(fileName)", "Saved remote file: \(fileName)"))
            } catch {
                workspace.error = L10n.tr("保存远程文件失败：\(error.localizedDescription)",
                                          "Failed to save remote file: \(error.localizedDescription)")
                ctx.isSaving = false
                self?.secondRemoteEditingFile = ctx
            }
        }
    }
}

// MARK: - Workspace Extension: Role-Aware Actions, New File, Symlinks & Bounded Cross-Pane Transfers

extension Workspace {
    private static let s2sStagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("AetherServerToServer", isDirectory: true)

    func navigatePane(to path: String, role: BrowserPaneRole, layout: PaneLayoutController) {
        layout.recordPathVisit(path, remote: role.isRemote)
        switch role {
        case .leftLocal:
            navigateLocal(to: path)
        case .primaryRemote:
            navigateRemote(to: path)
        case .secondLocal:
            layout.navigateSecondLocal(to: path, showHidden: showHidden)
        case .secondRemote:
            layout.navigateSecondRemote(to: path, workspace: self)
        }
    }

    func refreshPane(role: BrowserPaneRole, layout: PaneLayoutController) {
        switch role {
        case .leftLocal:
            refreshLocal()
        case .primaryRemote:
            refreshRemote()
        case .secondLocal:
            layout.refreshSecondLocal(showHidden: showHidden) { [weak self] msg in
                self?.error = msg
            }
        case .secondRemote:
            layout.refreshSecondRemote(workspace: self)
        }
    }

    func goBackPane(role: BrowserPaneRole, layout: PaneLayoutController) {
        switch role {
        case .leftLocal: goBack(remote: false)
        case .primaryRemote: goBack(remote: true)
        case .secondLocal: layout.goBackSecondLocal(showHidden: showHidden)
        case .secondRemote: layout.goBackSecondRemote(workspace: self)
        }
    }

    func goForwardPane(role: BrowserPaneRole, layout: PaneLayoutController) {
        switch role {
        case .leftLocal: goForward(remote: false)
        case .primaryRemote: goForward(remote: true)
        case .secondLocal: layout.goForwardSecondLocal(showHidden: showHidden)
        case .secondRemote: layout.goForwardSecondRemote(workspace: self)
        }
    }

    func parentPane(role: BrowserPaneRole, layout: PaneLayoutController) {
        switch role {
        case .leftLocal: parent(remote: false)
        case .primaryRemote: parent(remote: true)
        case .secondLocal: layout.parentSecondLocal(showHidden: showHidden)
        case .secondRemote: layout.parentSecondRemote(workspace: self)
        }
    }

    func currentPath(for role: BrowserPaneRole, layout: PaneLayoutController) -> String {
        switch role {
        case .leftLocal: return localPath
        case .primaryRemote: return remotePath
        case .secondLocal: return layout.secondLocalPath
        case .secondRemote: return layout.secondRemotePath
        }
    }

    func client(for role: BrowserPaneRole, layout: PaneLayoutController) -> RemoteClient? {
        switch role {
        case .primaryRemote: return client
        case .secondRemote: return layout.secondRemoteClient(speedLimit: speedLimit)
        case .leftLocal, .secondLocal: return nil
        }
    }

    func openEntry(_ entry: FileEntry, in role: BrowserPaneRole, layout: PaneLayoutController) {
        if entry.isDirectory {
            navigatePane(to: entry.path, role: role, layout: layout)
            return
        }
        switch role {
        case .leftLocal, .secondLocal:
            NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
        case .primaryRemote:
            download([entry])
        case .secondRemote:
            guard let secondClient = layout.secondRemoteClient(speedLimit: speedLimit) else { return }
            let targetLocalDir = (layout.leftPaneSource == .local) ? localPath : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
            transferRemoteToLocal([entry], client: secondClient, toLocalDir: targetLocalDir, targetLocalRole: .leftLocal)
        }
    }

    func previewEntry(_ entry: FileEntry, in role: BrowserPaneRole, layout: PaneLayoutController) {
        switch role {
        case .leftLocal, .secondLocal:
            previewURL = URL(fileURLWithPath: entry.path)
        case .primaryRemote:
            previewItem(entry, remote: true)
        case .secondRemote:
            guard !entry.isDirectory, let secondClient = layout.secondRemoteClient(speedLimit: speedLimit) else { return }
            isFetchingPreview = true
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPreview", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let cacheFile = tempDir.appendingPathComponent(entry.name)
            Task {
                do {
                    try await secondClient.download(entry.path, to: cacheFile, overwrite: true)
                    self.previewURL = cacheFile
                    self.isFetchingPreview = false
                } catch {
                    self.isFetchingPreview = false
                    self.error = L10n.tr("预览下载失败: \(error.localizedDescription)",
                                         "Preview download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func openEditorInPane(for entry: FileEntry, role: BrowserPaneRole, layout: PaneLayoutController) {
        switch role {
        case .leftLocal, .secondLocal:
            openEditor(for: entry, remote: false)
        case .primaryRemote:
            openEditor(for: entry, remote: true)
        case .secondRemote:
            guard let secondClient = layout.secondRemoteClient(speedLimit: speedLimit) else { return }
            Task {
                let tempCache = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aether-edit2-\(UUID().uuidString)-\(entry.name)")
                defer { try? FileManager.default.removeItem(at: tempCache) }
                do {
                    try await secondClient.download(entry.path, to: tempCache, overwrite: true)
                    let text = try await Task.detached(priority: .userInitiated) {
                        try String(contentsOf: tempCache, encoding: .utf8)
                    }.value
                    layout.secondRemoteEditingFile = EditingFileContext(name: entry.name, path: entry.path, remote: true, content: text)
                } catch {
                    self.error = L10n.tr("无法以文本形式打开此文件：\(error.localizedDescription)",
                                         "Unable to open file as text: \(error.localizedDescription)")
                }
            }
        }
    }

    func createFolder(in role: BrowserPaneRole, layout: PaneLayoutController) {
        if role == .leftLocal || role == .primaryRemote {
            createFolder(remote: role == .primaryRemote)
            return
        }
        guard let name = BrowserPromptHelper.askText(
            title: L10n.tr("新建文件夹", "New Folder"),
            initial: L10n.tr("新文件夹", "Untitled Folder")
        ) else { return }
        do {
            try RemotePath.validateName(name)
            switch role {
            case .secondLocal:
                let url = URL(fileURLWithPath: layout.secondLocalPath).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                refreshPane(role: .secondLocal, layout: layout)
            case .secondRemote:
                guard let client = layout.secondRemoteClient(speedLimit: speedLimit) else { return }
                let target = try RemotePath.join(layout.secondRemotePath, name)
                Task {
                    do {
                        try await client.mkdir(target)
                        refreshPane(role: .secondRemote, layout: layout)
                    } catch { self.error = error.localizedDescription }
                }
            default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createNewFile(remote: Bool) {
        createNewFile(in: remote ? .primaryRemote : .leftLocal, layout: nil, directoryOverride: nil)
    }

    func createNewFile(in role: BrowserPaneRole, layout: PaneLayoutController?, directoryOverride: String? = nil) {
        guard let name = BrowserPromptHelper.askText(
            title: L10n.tr("新建空文件", "New Empty File"),
            message: L10n.tr("请输入新文件名：", "Enter a name for the new file:"),
            initial: "untitled.txt"
        ) else { return }

        do {
            try RemotePath.validateName(name)
            let baseDir: String
            switch role {
            case .leftLocal: baseDir = directoryOverride ?? localPath
            case .primaryRemote: baseDir = directoryOverride ?? remotePath
            case .secondLocal: baseDir = directoryOverride ?? (layout?.secondLocalPath ?? localPath)
            case .secondRemote: baseDir = directoryOverride ?? (layout?.secondRemotePath ?? remotePath)
            }

            if !role.isRemote {
                let targetURL = URL(fileURLWithPath: baseDir).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    throw TransferError.conflict(name)
                }
                guard FileManager.default.createFile(atPath: targetURL.path, contents: Data()) else {
                    throw TransferError.remote(L10n.tr("无法创建文件 \(name)。", "Failed to create file \(name)."))
                }
                if let layout {
                    refreshPane(role: role, layout: layout)
                } else {
                    refreshLocal()
                }
            } else {
                let targetClient: RemoteClient? = (role == .secondRemote)
                    ? layout?.secondRemoteClient(speedLimit: speedLimit)
                    : client
                guard let targetClient else {
                    error = L10n.tr("请先连接服务器。", "Connect to a server first.")
                    return
                }
                let remoteFile = try RemotePath.join(baseDir, name)
                Task {
                    let tempEmpty = FileManager.default.temporaryDirectory
                        .appendingPathComponent("aether-newfile-\(UUID().uuidString)")
                    do {
                        FileManager.default.createFile(atPath: tempEmpty.path, contents: Data())
                        defer { try? FileManager.default.removeItem(at: tempEmpty) }
                        try await targetClient.upload(tempEmpty, to: remoteFile, overwrite: false)
                        if let layout {
                            self.refreshPane(role: role, layout: layout)
                        } else {
                            self.refreshRemote()
                        }
                        self.flashNotice(L10n.tr("已创建空文件：\(name)", "Created file: \(name)"))
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func createSymlink(for entry: FileEntry, in role: BrowserPaneRole, layout: PaneLayoutController?) {
        let defaultName = "\(entry.name)-link"
        guard let linkName = BrowserPromptHelper.askText(
            title: L10n.tr("创建符号链接", "Create Symbolic Link"),
            message: L10n.tr("指向目标：\(entry.path)", "Target: \(entry.path)"),
            initial: defaultName
        ) else { return }

        do {
            try RemotePath.validateName(linkName)
            let parentDir: String
            switch role {
            case .leftLocal: parentDir = RemotePath.parent(entry.path)
            case .secondLocal: parentDir = RemotePath.parent(entry.path)
            case .primaryRemote, .secondRemote: parentDir = RemotePath.parent(entry.path)
            }

            if !role.isRemote {
                let linkURL = URL(fileURLWithPath: parentDir).appendingPathComponent(linkName)
                if FileManager.default.fileExists(atPath: linkURL.path) {
                    throw TransferError.conflict(linkName)
                }
                try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: entry.path)
                if let layout {
                    refreshPane(role: role, layout: layout)
                } else {
                    refreshLocal()
                }
                flashNotice(L10n.tr("已创建符号链接：\(linkName)", "Created symlink: \(linkName)"))
            } else {
                let targetClient: RemoteClient? = (role == .secondRemote)
                    ? layout?.secondRemoteClient(speedLimit: speedLimit)
                    : client
                guard let targetClient else {
                    error = L10n.tr("请先连接服务器。", "Connect to a server first.")
                    return
                }
                let linkPath = try RemotePath.join(parentDir, linkName)
                Task {
                    do {
                        try await targetClient.createSymlink(target: entry.path, at: linkPath)
                        if let layout {
                            self.refreshPane(role: role, layout: layout)
                        } else {
                            self.refreshRemote()
                        }
                        self.flashNotice(L10n.tr("已创建符号链接：\(linkName)", "Created symlink: \(linkName)"))
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func renameEntry(_ entry: FileEntry, in role: BrowserPaneRole, layout: PaneLayoutController) {
        if role == .leftLocal || role == .primaryRemote {
            rename(entry, remote: role == .primaryRemote)
            return
        }
        guard let newName = BrowserPromptHelper.askText(title: L10n.tr("重命名", "Rename"), initial: entry.name) else { return }
        do {
            try RemotePath.validateName(newName)
            let parentDir = RemotePath.parent(entry.path)
            switch role {
            case .secondLocal:
                let target = URL(fileURLWithPath: parentDir).appendingPathComponent(newName)
                try FileManager.default.moveItem(at: URL(fileURLWithPath: entry.path), to: target)
                refreshPane(role: .secondLocal, layout: layout)
            case .secondRemote:
                guard let client = layout.secondRemoteClient(speedLimit: speedLimit) else { return }
                let target = try RemotePath.join(parentDir, newName)
                Task {
                    do {
                        try await client.rename(entry.path, to: target)
                        refreshPane(role: .secondRemote, layout: layout)
                    } catch { self.error = error.localizedDescription }
                }
            default: break
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteEntry(_ entry: FileEntry, in role: BrowserPaneRole, layout: PaneLayoutController) {
        if role == .leftLocal || role == .primaryRemote {
            delete(entry, remote: role == .primaryRemote)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.tr("删除 \(entry.name)？", "Delete \"\(entry.name)\"?")
        alert.informativeText = role.isRemote
            ? L10n.tr("服务器删除无法从本机废纸篓恢复。", "Remote deletion is permanent and cannot be undone from local Trash.")
            : L10n.tr("文件将移到废纸篓。", "The item will be moved to the Trash.")
        alert.addButton(withTitle: L10n.tr("删除", "Delete"))
        alert.addButton(withTitle: L10n.tr("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch role {
        case .secondLocal:
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                refreshPane(role: .secondLocal, layout: layout)
            } catch {
                self.error = error.localizedDescription
            }
        case .secondRemote:
            guard let client = layout.secondRemoteClient(speedLimit: speedLimit) else { return }
            Task {
                do {
                    try await client.remove(entry.path, directory: entry.isDirectory)
                    refreshPane(role: .secondRemote, layout: layout)
                } catch { self.error = error.localizedDescription }
            }
        default: break
        }
    }

    // MARK: - Bounded Cross-Pane Transfers (Local <-> Local, Local <-> 2nd Remote, Server <-> Server)

    /// Copies or moves local items between local panes using bounded 64 KiB streaming + atomic commit off main thread.
    func transferLocalBetweenPanes(
        _ entries: [FileEntry],
        toDirectory targetDirectory: String,
        move: Bool = false,
        sourceRole: BrowserPaneRole? = nil,
        targetRole: BrowserPaneRole,
        layout: PaneLayoutController
    ) {
        let destURL = URL(fileURLWithPath: targetDirectory).standardizedFileURL
        var existing = (try? FileManager.default.contentsOfDirectory(atPath: destURL.path)) ?? []
        var plans: [(source: URL, destination: URL, isDirectory: Bool, overwrite: Bool)] = []

        for entry in entries {
            let srcURL = URL(fileURLWithPath: entry.path).standardizedFileURL
            if srcURL.deletingLastPathComponent().path == destURL.path { continue }
            if destURL.path == srcURL.path || destURL.path.hasPrefix(srcURL.path + "/") { continue }
            guard let (resolvedName, overwrite) = BrowserPromptHelper.resolveConflict(
                name: entry.name,
                existing: existing,
                preference: defaultConflictPreference
            ) else { continue }
            existing.append(resolvedName)
            plans.append((srcURL, destURL.appendingPathComponent(resolvedName), entry.isDirectory, overwrite))
        }

        guard !plans.isEmpty else { return }

        for item in plans {
            let label = move
                ? "\(L10n.tr("移动", "Move")): \(item.source.lastPathComponent)"
                : "\(L10n.tr("本地复制", "Copy")): \(item.source.lastPathComponent)"
            _ = enqueueTransfer(name: label, direction: .upload) { [weak self] progress in
                if move && item.source.deletingLastPathComponent().path != item.destination.deletingLastPathComponent().path {
                    do {
                        if item.overwrite && FileManager.default.fileExists(atPath: item.destination.path) {
                            try FileManager.default.trashItem(at: item.destination, resultingItemURL: nil)
                        }
                        try FileManager.default.moveItem(at: item.source, to: item.destination)
                        progress(TransferProgress(completedBytes: 1, totalBytes: 1))
                        await MainActor.run {
                            guard let self else { return }
                            if let sourceRole { self.refreshPane(role: sourceRole, layout: layout) }
                            self.refreshPane(role: targetRole, layout: layout)
                        }
                        return
                    } catch {
                        // Cross-volume moves fall through to bounded copy + remove
                    }
                }

                if item.isDirectory {
                    try await Self.copyDirectoryChunked(from: item.source, to: item.destination, overwrite: item.overwrite, progress: progress)
                } else {
                    try await Self.copyFileChunked(from: item.source, to: item.destination, overwrite: item.overwrite, progress: progress)
                }
                if move {
                    try FileManager.default.trashItem(at: item.source, resultingItemURL: nil)
                }
                await MainActor.run {
                    guard let self else { return }
                    if let sourceRole, move { self.refreshPane(role: sourceRole, layout: layout) }
                    self.refreshPane(role: targetRole, layout: layout)
                }
            }
        }
    }

    /// Uploads local items to either primary or secondary remote server.
    func transferLocalToRemote(
        _ entries: [FileEntry],
        client targetClient: RemoteClient,
        toRemoteDir remoteDir: String,
        targetRole: BrowserPaneRole,
        layout: PaneLayoutController
    ) {
        guard !entries.isEmpty else { return }
        if targetRole == .primaryRemote {
            upload(entries, to: remoteDir)
            return
        }
        let normalizedTarget = RemotePath.normalize(remoteDir)
        let showHiddenFlag = showHidden
        let conflictPref = defaultConflictPreference

        Task { [weak self] in
            guard let self else { return }
            do {
                var existing = try await targetClient.list(normalizedTarget).map(\.name)
                for entry in entries {
                    guard let (targetName, overwrite) = BrowserPromptHelper.resolveConflict(
                        name: entry.name,
                        existing: existing,
                        preference: conflictPref
                    ) else { continue }
                    existing.append(targetName)

                    if entry.isDirectory {
                        let baseRemote = try RemotePath.join(normalizedTarget, targetName)
                        try await targetClient.mkdirRecursive(baseRemote)
                        let entryURL = URL(fileURLWithPath: entry.path)
                        let items = try await Task.detached(priority: .userInitiated) {
                            try LocalFiles.walk(entryURL, showHidden: showHiddenFlag)
                        }.value
                        for item in items {
                            let itemRemote = RemotePath.normalize(baseRemote + "/" + item.relativePath)
                            if item.isDirectory {
                                try await targetClient.mkdirRecursive(itemRemote)
                            } else {
                                try await targetClient.mkdirRecursive(RemotePath.parent(itemRemote))
                                _ = self.enqueueTransfer(name: "\(targetName)/\(item.relativePath)", direction: .upload) { [weak self] progress in
                                    let task = try ResumableTransfer(
                                        direction: .upload,
                                        local: item.fileURL,
                                        remote: itemRemote,
                                        profile: targetClient.profile,
                                        overwrite: overwrite
                                    )
                                    try await task.run(client: targetClient, progress: progress)
                                    await MainActor.run { self?.refreshPane(role: targetRole, layout: layout) }
                                }
                            }
                        }
                    } else {
                        let remoteDest = try RemotePath.join(normalizedTarget, targetName)
                        _ = self.enqueueTransfer(name: targetName, direction: .upload) { [weak self] progress in
                            let task = try ResumableTransfer(
                                direction: .upload,
                                local: URL(fileURLWithPath: entry.path),
                                remote: remoteDest,
                                profile: targetClient.profile,
                                overwrite: overwrite
                            )
                            try await task.run(client: targetClient, progress: progress)
                            await MainActor.run { self?.refreshPane(role: targetRole, layout: layout) }
                        }
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Downloads remote items from either primary or secondary remote server into any local pane directory.
    func transferRemoteToLocal(
        _ entries: [FileEntry],
        client sourceClient: RemoteClient,
        toLocalDir localDir: String,
        targetLocalRole: BrowserPaneRole,
        layout: PaneLayoutController? = nil
    ) {
        guard !entries.isEmpty else { return }
        if targetLocalRole == .leftLocal && sourceClient.profile.id == connectedProfile?.id {
            download(entries, to: localDir)
            return
        }
        let localParent = URL(fileURLWithPath: localDir)
        var existing = (try? FileManager.default.contentsOfDirectory(atPath: localDir)) ?? []
        for entry in entries {
            guard let (targetName, overwrite) = BrowserPromptHelper.resolveConflict(
                name: entry.name,
                existing: existing,
                preference: defaultConflictPreference
            ) else { continue }
            existing.append(targetName)

            if entry.isDirectory {
                let destFolder = localParent.appendingPathComponent(targetName)
                let remoteBase = entry.path
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
                        let items = try await sourceClient.listRecursive(remoteBase)
                        for item in items where item.path != remoteBase {
                            guard let rel = DragPathHelper.relativeSubpath(base: remoteBase, child: item.path) else { continue }
                            let targetURL = destFolder.appendingPathComponent(rel)
                            if item.isDirectory {
                                try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                            } else {
                                try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                                _ = self.enqueueTransfer(name: "\(targetName)/\(rel)", direction: .download) { [weak self] progress in
                                    let task = try ResumableTransfer(
                                        direction: .download,
                                        local: targetURL,
                                        remote: item.path,
                                        profile: sourceClient.profile,
                                        overwrite: overwrite
                                    )
                                    try await task.run(client: sourceClient, progress: progress)
                                    await MainActor.run {
                                        if let layout { self?.refreshPane(role: targetLocalRole, layout: layout) }
                                        else { self?.refreshLocal() }
                                    }
                                }
                            }
                        }
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            } else {
                let destURL = localParent.appendingPathComponent(targetName)
                _ = enqueueTransfer(name: targetName, direction: .download) { [weak self] progress in
                    let task = try ResumableTransfer(
                        direction: .download,
                        local: destURL,
                        remote: entry.path,
                        profile: sourceClient.profile,
                        overwrite: overwrite
                    )
                    try await task.run(client: sourceClient, progress: progress)
                    await MainActor.run {
                        if let layout { self?.refreshPane(role: targetLocalRole, layout: layout) }
                        else { self?.refreshLocal() }
                    }
                }
            }
        }
    }

    /// Server-to-Server transfer using bounded temp-file streaming off the main thread with automatic cleanup.
    func transferServerToServer(
        _ entries: [FileEntry],
        sourceClient: RemoteClient,
        destinationClient: RemoteClient,
        destinationDir: String,
        targetRole: BrowserPaneRole,
        layout: PaneLayoutController
    ) {
        guard !entries.isEmpty else { return }
        let normalizedDest = RemotePath.normalize(destinationDir)
        let conflictPref = defaultConflictPreference

        Task { [weak self] in
            guard let self else { return }
            do {
                var existing = try await destinationClient.list(normalizedDest).map(\.name)
                for entry in entries {
                    guard let (targetName, overwrite) = BrowserPromptHelper.resolveConflict(
                        name: entry.name,
                        existing: existing,
                        preference: conflictPref
                    ) else { continue }
                    existing.append(targetName)

                    if entry.isDirectory {
                        let baseRemoteDest = try RemotePath.join(normalizedDest, targetName)
                        try await destinationClient.mkdirRecursive(baseRemoteDest)
                        let items = try await sourceClient.listRecursive(entry.path)
                        for item in items where item.path != entry.path {
                            guard let rel = DragPathHelper.relativeSubpath(base: entry.path, child: item.path) else { continue }
                            let itemDest = RemotePath.normalize(baseRemoteDest + "/" + rel)
                            if item.isDirectory {
                                try await destinationClient.mkdirRecursive(itemDest)
                            } else {
                                try await destinationClient.mkdirRecursive(RemotePath.parent(itemDest))
                                self.enqueueSingleServerToServerFile(
                                    label: "\(targetName)/\(rel)",
                                    sourcePath: item.path,
                                    expectedSize: item.size,
                                    sourceClient: sourceClient,
                                    destinationPath: itemDest,
                                    destinationClient: destinationClient,
                                    overwrite: overwrite,
                                    targetRole: targetRole,
                                    layout: layout
                                )
                            }
                        }
                    } else {
                        let destPath = try RemotePath.join(normalizedDest, targetName)
                        self.enqueueSingleServerToServerFile(
                            label: "⇄ \(targetName)",
                            sourcePath: entry.path,
                            expectedSize: entry.size,
                            sourceClient: sourceClient,
                            destinationPath: destPath,
                            destinationClient: destinationClient,
                            overwrite: overwrite,
                            targetRole: targetRole,
                            layout: layout
                        )
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func enqueueSingleServerToServerFile(
        label: String,
        sourcePath: String,
        expectedSize: Int64,
        sourceClient: RemoteClient,
        destinationPath: String,
        destinationClient: RemoteClient,
        overwrite: Bool,
        targetRole: BrowserPaneRole,
        layout: PaneLayoutController
    ) {
        let stagingRoot = Self.s2sStagingRoot
        _ = enqueueTransfer(name: label, direction: .upload) { [weak self] progress in
            try Task.checkCancellation()
            let stagingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let tempFile = stagingDir.appendingPathComponent((sourcePath as NSString).lastPathComponent)
            defer { try? FileManager.default.removeItem(at: stagingDir) }

            let totalWeight = max(Int64(1), expectedSize) * 2
            let downloadTask = try ResumableTransfer(
                direction: .download,
                local: tempFile,
                remote: sourcePath,
                profile: sourceClient.profile,
                overwrite: true
            )
            try await downloadTask.run(client: sourceClient) { tp in
                let total = max(tp.total, max(Int64(1), expectedSize)) * 2
                progress(TransferProgress(completedBytes: tp.completed, totalBytes: total))
            }
            try Task.checkCancellation()

            let actualSize = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? expectedSize
            let half = max(Int64(0), actualSize)
            let uploadTask = try ResumableTransfer(
                direction: .upload,
                local: tempFile,
                remote: destinationPath,
                profile: destinationClient.profile,
                overwrite: overwrite
            )
            try await uploadTask.run(client: destinationClient) { tp in
                let total = max(totalWeight, half * 2)
                progress(TransferProgress(completedBytes: half + tp.completed, totalBytes: total))
            }
            await MainActor.run {
                self?.refreshPane(role: targetRole, layout: layout)
            }
        }
    }

    private nonisolated static func copyFileChunked(
        from source: URL,
        to destination: URL,
        overwrite: Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) && !overwrite {
            throw TransferError.conflict(destination.lastPathComponent)
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".aethertransfer-copy-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: staging) }

        let throttler = StreamingThrottler(speedLimitBytesPerSec: nil, chunkSize: 64 * 1024)
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let total = (attrs[.size] as? Int64) ?? 0
        let chunks = throttler.streamFileChunks(at: source)
        let handle: FileHandle = try await Task.detached {
            FileManager.default.createFile(atPath: staging.path, contents: nil)
            return try FileHandle(forWritingTo: staging)
        }.value
        var closed = false
        defer {
            if !closed { try? handle.close() }
        }

        var completed: Int64 = 0
        progress(TransferProgress(completedBytes: 0, totalBytes: total))
        for try await chunk in chunks {
            try Task.checkCancellation()
            try await Task.detached { try handle.write(contentsOf: chunk) }.value
            completed += Int64(chunk.count)
            progress(TransferProgress(completedBytes: completed, totalBytes: max(total, completed)))
        }
        try handle.close()
        closed = true
        try Task.checkCancellation()
        try await LocalFileCommit.commit(staging, to: destination, overwrite: overwrite)
    }

    private nonisolated static func copyDirectoryChunked(
        from source: URL,
        to destination: URL,
        overwrite: Bool,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try LocalFiles.walk(source, showHidden: true)
        let totalBytes = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + max(0, $1.size) }
        var accumulated: Int64 = 0
        progress(TransferProgress(completedBytes: 0, totalBytes: max(1, totalBytes)))

        for item in items {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(item.relativePath)
            if item.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let baseCompleted = accumulated
                try await copyFileChunked(from: item.fileURL, to: target, overwrite: overwrite) { tp in
                    progress(TransferProgress(completedBytes: baseCompleted + tp.completed, totalBytes: max(1, totalBytes)))
                }
                accumulated += max(0, item.size)
            }
        }
    }
}
