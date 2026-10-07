import Foundation
import XCTest
@testable import AetherTransferCore

@MainActor final class ProtocolIntegrationTests: XCTestCase {
    func client(_ kind: TransferProtocol, trusted: Bool = true) throws -> RemoteClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env[kind == .ftp ? "AT_FTP_PORT" : "AT_SFTP_PORT"], let number = Int(port) else {
            throw XCTSkip("Run scripts/test_protocols.sh for isolated real FTP/SFTP servers")
        }
        return RemoteClient(profile: ServerProfile(host: "127.0.0.1", port: number, username: "fixture", protocolKind: kind,
                                                  trustedHostKey: trusted && kind == .sftp ? env["AT_SFTP_KEY"] : nil),
                            credentials: Credentials(password: "fixture-only"))
    }
    func roundTrip(_ kind: TransferProtocol) async throws {
        let remote = try client(kind)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        let data = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: source)
        let path = "/\(kind.rawValue)-\(UUID().uuidString) 空格"
        try await remote.mkdir(path)
        let target = try RemotePath.join(path, "中文 # 文件.txt")
        try await remote.upload(source, to: target)
        let listing = try await remote.list(path)
        XCTAssertEqual(listing.count, 1); XCTAssertEqual(listing[0].name, "中文 # 文件.txt")
        XCTAssertEqual(listing[0].size, Int64(data.count))
        let download = folder.appendingPathComponent("download")
        try await remote.download(target, to: download)
        XCTAssertEqual(try Data(contentsOf: download), data)
        do { try await remote.upload(source, to: target); XCTFail("Conflict must reject") }
        catch TransferError.conflict { }
        let renamed = try RemotePath.join(path, "renamed.txt")
        try await remote.rename(target, to: renamed)
        try await remote.remove(renamed, directory: false)
        let empty = try await remote.list(path)
        XCTAssertTrue(empty.isEmpty)
        try await remote.remove(path, directory: true)
    }
    func testFTPRoundTrip() async throws { try await roundTrip(.ftp) }
    func testSFTPRoundTrip() async throws { try await roundTrip(.sftp) }
    func testSFTPRejectsUntrustedAndChangedHostKey() async throws {
        let untrusted = try client(.sftp, trusted: false)
        do { _ = try await untrusted.list("/"); XCTFail("Untrusted host must be rejected") }
        catch TransferError.hostKeyRequired(let key, let changed) {
            XCTAssertFalse(changed); XCTAssertFalse(key.isEmpty)
            XCTAssertEqual(key, ProcessInfo.processInfo.environment["AT_SFTP_KEY"])
        }
        var changed = untrusted.profile; changed.trustedHostKey = "ZmFrZQ=="
        do { _ = try await RemoteClient(profile: changed, credentials: untrusted.credentials).list("/"); XCTFail("Changed host must be rejected") }
        catch TransferError.hostKeyRequired(_, let changed) { XCTAssertTrue(changed) }
    }
    func testFailedDownloadPreservesExistingDestination() async throws {
        let remote = try client(.ftp)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let data = Data("keep this".utf8); try data.write(to: destination)
        do { try await remote.download("/missing-\(UUID().uuidString)", to: destination, overwrite: true); XCTFail("Missing download must fail") }
        catch { XCTAssertEqual(try Data(contentsOf: destination), data) }
    }
}
