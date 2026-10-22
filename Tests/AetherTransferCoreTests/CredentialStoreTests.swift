import XCTest
@testable import AetherTransferCore

final class CredentialStoreTests: XCTestCase {
    /// 使用随机 ID 读写登录钥匙串，结束时删除；钥匙串不可用（如无界面的 CI）时跳过。
    func testRememberStoresAndForgetDeletesCredentials() throws {
        let id = UUID()
        defer { try? CredentialStore.store(Credentials(), id: id, remember: false) }
        do {
            try CredentialStore.store(Credentials(password: "pw-测试", passphrase: "phrase"), id: id, remember: true)
        } catch TransferError.keychain(let status) {
            throw XCTSkip("Keychain unavailable (\(status))")
        }
        var loaded = try CredentialStore.loadCredentials(id: id)
        XCTAssertEqual(loaded.password, "pw-测试")
        XCTAssertEqual(loaded.passphrase, "phrase")

        try CredentialStore.store(Credentials(password: "new", passphrase: ""), id: id, remember: true)
        loaded = try CredentialStore.loadCredentials(id: id)
        XCTAssertEqual(loaded.password, "new")
        XCTAssertEqual(loaded.passphrase, "")

        try CredentialStore.store(Credentials(password: "ignored", passphrase: "ignored"), id: id, remember: false)
        loaded = try CredentialStore.loadCredentials(id: id)
        XCTAssertEqual(loaded.password, "")
        XCTAssertEqual(loaded.passphrase, "")
    }
}
