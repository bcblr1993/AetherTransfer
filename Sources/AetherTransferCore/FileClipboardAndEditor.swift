import Foundation
import CryptoKit

// MARK: - Cross-Pane File Clipboard & URL Copy Helpers (Transmit Parity)
public enum ClipboardOperation: String, Sendable {
    case copy
    case move
}

public struct FileClipboardPayload: Sendable {
    public let entries: [FileEntry]
    public let sourceRemote: Bool
    public let sourceProfileId: UUID?
    public let operation: ClipboardOperation
    public let copiedAt: Date

    public init(entries: [FileEntry], sourceRemote: Bool, sourceProfileId: UUID? = nil, operation: ClipboardOperation = .copy, copiedAt: Date = Date()) {
        self.entries = entries
        self.sourceRemote = sourceRemote
        self.sourceProfileId = sourceProfileId
        self.operation = operation
        self.copiedAt = copiedAt
    }
}

public enum FileClipboard {
    /// Generates a duplicate name in the same directory (e.g. `config.json` -> `config copy.json`).
    public static func duplicateName(for originalName: String, existingNames: [String]) -> String {
        let dotIndex = originalName.lastIndex(of: ".")
        let base: String
        let ext: String
        if let dot = dotIndex, dot != originalName.startIndex {
            base = String(originalName[..<dot])
            ext = String(originalName[dot...])
        } else {
            base = originalName
            ext = ""
        }
        let suffix = L10n.isEnglish ? " copy" : " 副本"
        let firstCandidate = "\(base)\(suffix)\(ext)"
        if !existingNames.contains(firstCandidate) {
            return firstCandidate
        }
        return RemotePath.uniqueName(for: firstCandidate, existingNames: existingNames)
    }

    /// Formats a public or protocol URL for a remote entry.
    public static func remoteURLString(for entry: FileEntry, profile: ServerProfile) -> String {
        if profile.protocolKind == .s3 {
            if let url = try? S3Client(profile: profile, credentials: Credentials()).endpointURL(objectKey: S3Client.s3ObjectKey(for: entry.path, isDirectory: entry.isDirectory)) {
                return url.absoluteString
            }
        }
        return (try? profile.url(path: entry.path, directory: entry.isDirectory)) ?? entry.path
    }
}

// MARK: - External Editor Live File Watcher & Auto-Upload Manager
public struct ExternalEditorSession: Identifiable, Sendable {
    public let id: UUID
    public let entryName: String
    public let remotePath: String
    public let localFileURL: URL
    public let profile: ServerProfile
    public var lastKnownDigest: String
    public var lastUploadedAt: Date?
    public var uploadCount: Int

    public init(id: UUID = UUID(), entryName: String, remotePath: String, localFileURL: URL, profile: ServerProfile, lastKnownDigest: String, lastUploadedAt: Date? = nil, uploadCount: Int = 0) {
        self.id = id
        self.entryName = entryName
        self.remotePath = remotePath
        self.localFileURL = localFileURL
        self.profile = profile
        self.lastKnownDigest = lastKnownDigest
        self.lastUploadedAt = lastUploadedAt
        self.uploadCount = uploadCount
    }
}

public final class ExternalEditorManager: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: ExternalEditorSession] = [:]
    public let stagingRootDirectory: URL

    public init(stagingRootDirectory: URL? = nil) {
        let root = stagingRootDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("AetherExternalEdit", isDirectory: true)
        self.stagingRootDirectory = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func fileDigest(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func registerSession(entryName: String, remotePath: String, localFileURL: URL, profile: ServerProfile) throws -> ExternalEditorSession {
        let digest = try Self.fileDigest(at: localFileURL)
        let session = ExternalEditorSession(
            entryName: entryName,
            remotePath: remotePath,
            localFileURL: localFileURL,
            profile: profile,
            lastKnownDigest: digest
        )
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
        return session
    }

    public func activeSessions() -> [ExternalEditorSession] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values).sorted { $0.entryName < $1.entryName }
    }

    /// Scans all active external editor sessions and returns those whose on-disk SHA-256 digest changed since last upload.
    public func drainModifiedSessions() -> [ExternalEditorSession] {
        lock.lock()
        defer { lock.unlock() }
        var modified: [ExternalEditorSession] = []
        for (id, var session) in sessions {
            guard FileManager.default.fileExists(atPath: session.localFileURL.path),
                  let currentDigest = try? Self.fileDigest(at: session.localFileURL),
                  currentDigest != session.lastKnownDigest else {
                continue
            }
            session.lastKnownDigest = currentDigest
            session.lastUploadedAt = Date()
            session.uploadCount += 1
            sessions[id] = session
            modified.append(session)
        }
        return modified
    }

    public func removeSession(id: UUID) {
        lock.lock()
        let removed = sessions.removeValue(forKey: id)
        lock.unlock()
        if let removed {
            try? FileManager.default.removeItem(at: removed.localFileURL.deletingLastPathComponent())
        }
    }

    public func clearAll() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: stagingRootDirectory)
    }
}

// MARK: - ApexTerm & Native Terminal Integration
public enum TerminalAppKind: String, Sendable {
    case apexTerm = "ApexTerm"
    case appleTerminal = "Terminal"
}

public enum TerminalIntegration {
    public static func detectPreferredTerminal(fileManager: FileManager = .default) -> (kind: TerminalAppKind, appURL: URL?) {
        let candidates = [
            URL(fileURLWithPath: "/Applications/ApexTerm.app"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ApexTerm.app")
        ]
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return (.apexTerm, url)
        }
        return (.appleTerminal, URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    public static func sshCommand(for profile: ServerProfile) -> String {
        let target = ShellEscape.singleQuoted("\(profile.username)@\(profile.host)")
        var cmd = "ssh -p \(profile.port)"
        if !profile.privateKeyPath.isEmpty {
            cmd += " -i \(ShellEscape.singleQuoted(profile.privateKeyPath))"
        }
        cmd += " \(target)"
        return cmd
    }
}
