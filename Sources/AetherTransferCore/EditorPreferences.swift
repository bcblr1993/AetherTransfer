import Combine
import Foundation

@MainActor
public final class FilesPreferencesStore: ObservableObject {
    public static let shared = FilesPreferencesStore()

    private enum DefaultsKey {
        static let doubleClickAction = "com.aethernative.AetherTransfer.filesPrefs.doubleClickAction"
        static let defaultExternalEditorPath = "com.aethernative.AetherTransfer.filesPrefs.defaultExternalEditorPath"
        static let customEditors = "com.aethernative.AetherTransfer.filesPrefs.customEditors"
        static let askBeforeDeleting = "com.aethernative.AetherTransfer.filesPrefs.askBeforeDeleting"
        static let transferMode = "com.aethernative.AetherTransfer.filesPrefs.transferMode"
        static let notifyOnTransferComplete = "com.aethernative.AetherTransfer.filesPrefs.notifyOnTransferComplete"
        static let playSoundOnTransferComplete = "com.aethernative.AetherTransfer.filesPrefs.playSoundOnTransferComplete"
    }

    private let userDefaults: UserDefaults

    @Published public var doubleClickAction: DoubleClickAction {
        didSet {
            userDefaults.set(doubleClickAction.rawValue, forKey: DefaultsKey.doubleClickAction)
        }
    }

    @Published public var defaultExternalEditorPath: String {
        didSet {
            userDefaults.set(defaultExternalEditorPath, forKey: DefaultsKey.defaultExternalEditorPath)
        }
    }

    @Published public var customEditors: [CustomEditorMapping] {
        didSet {
            persistCustomEditors()
        }
    }

    @Published public var askBeforeDeleting: Bool {
        didSet {
            userDefaults.set(askBeforeDeleting, forKey: DefaultsKey.askBeforeDeleting)
        }
    }

    @Published public var transferMode: TransferMode {
        didSet {
            userDefaults.set(transferMode.rawValue, forKey: DefaultsKey.transferMode)
        }
    }

    @Published public var notifyOnTransferComplete: Bool {
        didSet {
            userDefaults.set(notifyOnTransferComplete, forKey: DefaultsKey.notifyOnTransferComplete)
        }
    }

    @Published public var playSoundOnTransferComplete: Bool {
        didSet {
            userDefaults.set(playSoundOnTransferComplete, forKey: DefaultsKey.playSoundOnTransferComplete)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let rawDoubleClick = userDefaults.string(forKey: DefaultsKey.doubleClickAction) ?? ""
        self.doubleClickAction = DoubleClickAction(rawValue: rawDoubleClick) ?? .transfer

        self.defaultExternalEditorPath = userDefaults.string(forKey: DefaultsKey.defaultExternalEditorPath) ?? ""

        if let data = userDefaults.data(forKey: DefaultsKey.customEditors),
           let decoded = try? JSONDecoder().decode([CustomEditorMapping].self, from: data) {
            self.customEditors = decoded
        } else {
            self.customEditors = []
        }

        if userDefaults.object(forKey: DefaultsKey.askBeforeDeleting) != nil {
            self.askBeforeDeleting = userDefaults.bool(forKey: DefaultsKey.askBeforeDeleting)
        } else {
            self.askBeforeDeleting = true
        }

        let rawMode = userDefaults.string(forKey: DefaultsKey.transferMode) ?? ""
        self.transferMode = TransferMode(rawValue: rawMode) ?? .automatic

        if userDefaults.object(forKey: DefaultsKey.notifyOnTransferComplete) != nil {
            self.notifyOnTransferComplete = userDefaults.bool(forKey: DefaultsKey.notifyOnTransferComplete)
        } else {
            self.notifyOnTransferComplete = true
        }

        if userDefaults.object(forKey: DefaultsKey.playSoundOnTransferComplete) != nil {
            self.playSoundOnTransferComplete = userDefaults.bool(forKey: DefaultsKey.playSoundOnTransferComplete)
        } else {
            self.playSoundOnTransferComplete = false
        }
    }

    public func preferredEditorURL(for filename: String) -> URL? {
        Self.preferredEditorURL(
            for: filename,
            customEditors: customEditors,
            defaultExternalEditorPath: defaultExternalEditorPath
        )
    }

    public nonisolated static func preferredEditorURL(
        for filename: String,
        customEditors: [CustomEditorMapping],
        defaultExternalEditorPath: String
    ) -> URL? {
        let ext = normalizedExtension(fromFilename: filename)
        if !ext.isEmpty {
            if let matched = customEditors.first(where: {
                normalizedExtension($0.fileExtension) == ext &&
                !$0.appPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                return URL(fileURLWithPath: matched.appPath.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let trimmedDefault = defaultExternalEditorPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDefault.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmedDefault)
    }

    public func upsertCustomEditor(fileExtension: String, appPath: String, appName: String) {
        let normalizedExt = Self.normalizedExtension(fileExtension)
        let trimmedPath = appPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedExt.isEmpty, !trimmedPath.isEmpty else { return }
        let resolvedName = appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? URL(fileURLWithPath: trimmedPath).deletingPathExtension().lastPathComponent
            : appName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let index = customEditors.firstIndex(where: { Self.normalizedExtension($0.fileExtension) == normalizedExt }) {
            customEditors[index].fileExtension = normalizedExt
            customEditors[index].appPath = trimmedPath
            customEditors[index].appName = resolvedName
        } else {
            customEditors.append(
                CustomEditorMapping(
                    fileExtension: normalizedExt,
                    appPath: trimmedPath,
                    appName: resolvedName
                )
            )
        }
    }

    public func removeCustomEditor(id: UUID) {
        customEditors.removeAll { $0.id == id }
    }

    private func persistCustomEditors() {
        if let data = try? JSONEncoder().encode(customEditors) {
            userDefaults.set(data, forKey: DefaultsKey.customEditors)
        }
    }

    private nonisolated static func normalizedExtension(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private nonisolated static func normalizedExtension(fromFilename filename: String) -> String {
        let trimmedName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dotIndex = trimmedName.lastIndex(of: "."), dotIndex != trimmedName.startIndex else {
            return ""
        }
        return String(trimmedName[trimmedName.index(after: dotIndex)...]).lowercased()
    }
}
