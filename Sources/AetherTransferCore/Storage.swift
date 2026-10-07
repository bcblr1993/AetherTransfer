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
}

public enum CredentialStore {
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
