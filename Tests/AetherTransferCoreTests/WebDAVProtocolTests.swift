import Foundation
import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    func testWebDAVAuthenticationRedirectsAndPartialFailureReject() async throws {
        for kind in [TransferProtocol.webdav, .webdavs] {
            let remote = try client(kind)
            let wrong = RemoteClient(profile: remote.profile, credentials: Credentials(password: "incorrect"),
                                     certificateAuthority: remote.certificateAuthority)
            do { _ = try await wrong.list("/"); XCTFail("Incorrect credentials must fail") }
            catch TransferError.remote(let message) { XCTAssertEqual(message, L10n.text("WebDAV 认证失败，请检查用户名和密码。")) }
            do { _ = try await remote.list("/__aether_fixture_redirect__"); XCTFail("Redirect must be rejected, including HTTPS to HTTP") }
            catch TransferError.remote(let message) { XCTAssertEqual(message, L10n.text("服务器重定向了请求。请直接填写最终 WebDAV 地址。")) }
            do { try await remote.remove("/__aether_fixture_partial__", directory: false); XCTFail("207 mutation errors cannot become success") }
            catch TransferError.remote(let message) { XCTAssertTrue(message.contains("207")) }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-dav-failure-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: destination) }
            let original = Data("preserve original".utf8); try original.write(to: destination)
            do { try await remote.download("/missing-\(UUID().uuidString)", to: destination, overwrite: true); XCTFail("Missing resource must fail") }
            catch { XCTAssertEqual(try Data(contentsOf: destination), original) }
        }
        let remote = try client(.webdav)
        var profile = remote.profile
        profile.port = try XCTUnwrap(Int(ProcessInfo.processInfo.environment["AT_WEBDAV_DIGEST_PORT"] ?? ""))
        let digest = RemoteClient(profile: profile, credentials: remote.credentials)
        let listing = try await digest.list("/")
        XCTAssertTrue(listing.contains { $0.name == "中文 seed.txt" })
        profile.protocolKind = .webdavs; profile.port = remote.profile.port
        do { _ = try await RemoteClient(profile: profile, credentials: remote.credentials).list("/"); XCTFail("HTTPS must reject a plaintext HTTP server") }
        catch TransferError.remote { }
    }
    func testWebDAVMoveNoClobberAndNonemptyCollectionProtection() async throws {
        let remote = try client(.webdavs)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-dav-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source"), proof = folder.appendingPathComponent("proof")
        let root = "/dav-move-\(UUID().uuidString)", moved = root + " renamed"
        try await remote.mkdir(root)
        try Data("AAA".utf8).write(to: source); try await remote.upload(source, to: root + "/from")
        try Data("BBB".utf8).write(to: source); try await remote.upload(source, to: root + "/to")
        do { try await remote.rename(root + "/from", to: root + "/to"); XCTFail("MOVE must reject existing target") }
        catch TransferError.conflict(let name) { XCTAssertEqual(name, "to") }
        try await remote.download(root + "/to", to: proof)
        XCTAssertEqual(try Data(contentsOf: proof), Data("BBB".utf8))
        try await remote.download(root + "/from", to: proof, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: proof), Data("AAA".utf8))
        do { try await remote.remove(root, directory: true); XCTFail("Do not silently perform recursive DELETE") }
        catch TransferError.remote { }
        try await remote.rename(root, to: moved)
        let listing = try await remote.list(moved)
        XCTAssertEqual(Set(listing.map(\.name)), ["from", "to"])
        try await remote.remove(moved + "/from", directory: false)
        try await remote.remove(moved + "/to", directory: false)
        try await remote.remove(moved, directory: true)
    }
    func testWebDAVCancelledUploadPreservesTargetAndRemovesStaging() async throws {
        for kind in [TransferProtocol.webdav, .webdavs] {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-dav-cancel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source"), proof = folder.appendingPathComponent("proof")
            let path = "/dav-cancel-\(UUID().uuidString)"
            try await remote.mkdir(path)
            try Data("original".utf8).write(to: source); try await remote.upload(source, to: path + "/target")
            try Data(repeating: 17, count: 512 * 1024).write(to: source)
            let started = expectation(description: "WebDAV PUT sends bytes")
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, rateLimit: 64 * 1024,
                                    certificateAuthority: remote.certificateAuthority)
            let operation = Task {
                try await slow.upload(source, to: path + "/target", overwrite: true, progress: { progress in
                    if progress.completed > 0 { started.fulfill() }
                })
            }
            started.assertForOverFulfill = false
            await fulfillment(of: [started], timeout: 4)
            operation.cancel()
            do { try await operation.value; XCTFail("Cancelled PUT must fail") }
            catch is CancellationError { }
            try await remote.download(path + "/target", to: proof)
            XCTAssertEqual(try Data(contentsOf: proof), Data("original".utf8))
            let remaining = try await remote.list(path)
            XCTAssertEqual(remaining.map(\.name), ["target"], "Only the final original file may remain")
        }
    }
}
