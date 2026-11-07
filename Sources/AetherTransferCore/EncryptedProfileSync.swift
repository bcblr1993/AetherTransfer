import Foundation
import CryptoKit

// MARK: - Zero-Knowledge Encrypted Bookmark Sync (Transmit Panic Sync Parity)
public struct EncryptedSyncPayload: Codable, Sendable {
    public let version: Int
    public let exportedAt: Date
    public let profiles: [ServerProfile]

    public init(version: Int = 1, exportedAt: Date = Date(), profiles: [ServerProfile]) {
        self.version = version
        self.exportedAt = exportedAt
        self.profiles = profiles
    }
}

public struct EncryptedVaultEnvelope: Codable, Sendable {
    public let magic: String
    public let version: Int
    public let kdfSaltBase64: String
    public let nonceBase64: String
    public let ciphertextBase64: String
    public let tagBase64: String
}

public enum EncryptedProfileSyncError: Error, LocalizedError, Sendable {
    case emptyPassword
    case invalidVaultFormat
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return L10n.tr("加密主密码不能为空。", "Master encryption password cannot be empty.")
        case .invalidVaultFormat:
            return L10n.tr("加密同步文件格式无效或已损坏。", "Invalid or corrupted encrypted sync vault.")
        case .decryptionFailed:
            return L10n.tr("主密码错误或密文校验失败 (AES-GCM-256)。", "Incorrect master password or authentication tag mismatch (AES-GCM-256).")
        }
    }
}

public enum EncryptedProfileSync {
    private static let magicHeader = "AETHER-VAULT-V1"
    private static let hkdfInfo = Data("com.aethernative.AetherTransfer.vault.v1".utf8)

    /// Encrypts server profiles with AES-GCM-256 using a key derived via HKDF-SHA256.
    public static func encrypt(profiles: [ServerProfile], masterPassword: String) throws -> Data {
        guard !masterPassword.isEmpty else { throw EncryptedProfileSyncError.emptyPassword }

        var saltBytes = [UInt8](repeating: 0, count: 32)
        for i in saltBytes.indices { saltBytes[i] = UInt8.random(in: 0...255) }
        let salt = Data(saltBytes)

        let key = deriveKey(password: masterPassword, salt: salt)
        let payload = EncryptedSyncPayload(profiles: profiles)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)

        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data(magicHeader.utf8))

        let envelope = EncryptedVaultEnvelope(
            magic: magicHeader,
            version: 1,
            kdfSaltBase64: salt.base64EncodedString(),
            nonceBase64: Data(nonce).base64EncodedString(),
            ciphertextBase64: sealedBox.ciphertext.base64EncodedString(),
            tagBase64: sealedBox.tag.base64EncodedString()
        )
        let outEncoder = JSONEncoder()
        outEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try outEncoder.encode(envelope)
    }

    /// Decrypts and verifies an `.aethersync` vault bundle using the master password.
    public static func decrypt(vaultData: Data, masterPassword: String) throws -> [ServerProfile] {
        guard !masterPassword.isEmpty else { throw EncryptedProfileSyncError.emptyPassword }
        guard let envelope = try? JSONDecoder().decode(EncryptedVaultEnvelope.self, from: vaultData),
              envelope.magic == magicHeader,
              let salt = Data(base64Encoded: envelope.kdfSaltBase64),
              let nonceData = Data(base64Encoded: envelope.nonceBase64),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let ciphertext = Data(base64Encoded: envelope.ciphertextBase64),
              let tag = Data(base64Encoded: envelope.tagBase64) else {
            throw EncryptedProfileSyncError.invalidVaultFormat
        }

        let key = deriveKey(password: masterPassword, salt: salt)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw EncryptedProfileSyncError.invalidVaultFormat
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: Data(magicHeader.utf8))
        } catch {
            throw EncryptedProfileSyncError.decryptionFailed
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(EncryptedSyncPayload.self, from: plaintext)
        return payload.profiles
    }

    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        // Stretch password with 10,000 rounds of SHA-256 + salt before HKDF extraction
        var digest = Data(SHA256.hash(data: salt + Data(password.utf8)))
        for round in 0..<10_000 {
            var input = digest
            var r = UInt32(round).littleEndian
            withUnsafeBytes(of: &r) { input.append(contentsOf: $0) }
            digest = Data(SHA256.hash(data: input))
        }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: digest),
            salt: salt,
            info: hkdfInfo,
            outputByteCount: 32
        )
    }
}
