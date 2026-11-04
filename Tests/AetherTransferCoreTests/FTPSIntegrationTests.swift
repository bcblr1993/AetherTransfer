import Foundation
import XCTest
import CTransfer

final class FTPSIntegrationTests: XCTestCase {
    func testTrustedCertificateRoundTripAndUntrustedCertificateRejection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["AT_FTPS_PORT"], let ca = env["AT_FTPS_CA"] else {
            throw XCTSkip("Run scripts/test_protocols.sh for isolated FTPS")
        }
        try await Task.detached {
            let url = "ftps://127.0.0.1:\(port)/"
            func request(_ target: String, trusted: Bool) throws -> OpaquePointer {
                let pointer = try XCTUnwrap(at_create(target, "fixture", "fixture-only", "", "", ""))
                if trusted { XCTAssertEqual(at_set_ca_bundle(pointer, ca), 0) }
                return pointer
            }
            let untrusted = try request(url, trusted: false)
            defer { at_destroy(untrusted) }
            // libcurl's peer-verification failure; trust must never be disabled.
            XCTAssertEqual(at_perform(untrusted, 0, "", "", nil, nil), 60)

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aether-ftps-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source")
            let destination = folder.appendingPathComponent("download")
            let bytes = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
            try bytes.write(to: source)
            let remoteURL = url + "ftps-roundtrip-\(UUID().uuidString).bin"
            let upload = try request(remoteURL, trusted: true)
            defer { at_destroy(upload) }
            XCTAssertEqual(at_perform(upload, 2, source.path, "", nil, nil), 0, String(cString: at_error(upload)))
            let download = try request(remoteURL, trusted: true)
            defer { at_destroy(download) }
            XCTAssertEqual(at_perform(download, 1, destination.path, "", nil, nil), 0, String(cString: at_error(download)))
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }.value
    }
}
