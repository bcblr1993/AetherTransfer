import Foundation
import Security

public struct ProfileStore: Sendable {
    public let file: URL
    public init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherTransfer/servers.json")
    }
    public func load() throws -> [ServerProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ServerProfile].self, from: Data(contentsOf: file))
    }
    public func save(_ profiles: [ServerProfile]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func importing(_ data: Data, into existing: [ServerProfile]) throws -> [ServerProfile] {
        guard data.count <= 1024 * 1024 else { throw TransferError.remote(L10n.text("收藏文件超过 1 MiB。")) }
        let imported = try JSONDecoder().decode([ServerProfile].self, from: data)
        guard imported.count <= 1000, Set(imported.map(\.id)).count == imported.count else {
            throw TransferError.remote(L10n.text("收藏数量过多或包含重复标识。"))
        }
        var result = existing
        for var profile in imported {
            try profile.validate()
            // Importing must not authorize a host, local key or the local agent.
            profile.trustedHostKey = nil; profile.privateKeyPath = ""; profile.sshAuthentication = nil
            profile.s3CertificateAuthorityPath = nil
            // An imported UUID must never select credentials already stored on this Mac.
            profile.credentialID = UUID(); profile.retiredCredentialIDs = nil
            if result.contains(where: { $0.id == profile.id }) { profile.id = UUID() }
            result.append(profile)
        }
        return result
    }
}

public enum CredentialStore {
    private static let kinds = ["password", "passphrase", "s3-access", "s3-secret", "s3-session"]
    public static func save(_ credentials: Credentials, profile: ServerProfile, remember: Bool) throws {
        let credentials = credentials.forProfile(profile)
        let values = profile.protocolKind == .s3
            ? ["s3-access": credentials.accessKey, "s3-secret": credentials.secretKey, "s3-session": credentials.sessionToken]
            : ["password": credentials.password, "passphrase": credentials.passphrase]
        for kind in kinds { try save(remember ? values[kind] ?? "" : "", id: profile.credentialID ?? profile.id, kind: kind) }
    }
    public static func load(profile: ServerProfile) throws -> Credentials {
        if profile.protocolKind == .sftp && profile.effectiveSSHAuthentication == .agent { return Credentials() }
        let id = profile.credentialID ?? profile.id
        if profile.protocolKind == .s3 {
            return try Credentials(accessKey: load(id: id, kind: "s3-access"), secretKey: load(id: id, kind: "s3-secret"), sessionToken: load(id: id, kind: "s3-session"))
        }
        if profile.protocolKind == .sftp && profile.effectiveSSHAuthentication == .privateKey {
            return try Credentials(passphrase: load(id: id, kind: "passphrase"))
        }
        return try Credentials(password: load(id: id))
    }
    public static func remove(id: UUID) throws { for kind in kinds { try save("", id: id, kind: kind) } }
    private static func query(_ id: UUID, kind: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.aethernative.AetherTransfer",
         kSecAttrAccount as String: "\(id.uuidString).\(kind)"]
    }
    public static func save(_ value: String, id: UUID, kind: String = "password") throws {
        let q = query(id, kind: kind)
        if value.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TransferError.keychain(status) }
            return
        }
        let attrs = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q; insert.merge(attrs) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TransferError.keychain(status) }
    }
    public static func load(id: UUID, kind: String = "password") throws -> String {
        var q = query(id, kind: kind); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw TransferError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }
}
