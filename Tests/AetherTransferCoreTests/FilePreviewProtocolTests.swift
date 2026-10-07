import Foundation
import XCTest
@testable import AetherTransferCore

private final class PreviewProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var announced = false
    let started: XCTestExpectation
    init(_ started: XCTestExpectation) { self.started = started }
    func receive(_ value: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        if value.phase == nil && value.completed > 0 && !announced { announced = true; started.fulfill() }
    }
}

extension ProtocolIntegrationTests {
    func testRemotePreviewReservedFilenamePreservesLeaseForEveryProtocol() async throws {
        for kind in TransferProtocol.allCases {
            let remote = try client(kind), root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), folder = "/preview-reserved-\(UUID())"
            let data = Data("server file named .lease".utf8); try data.write(to: source)
            try await remote.mkdir(folder)
            let target = try RemotePath.join(folder, ".lease")
            try await remote.upload(source, to: target)
            let preview = try await FilePreview.open(.remote(remote, target), temporaryParent: root)
            XCTAssertEqual(preview.url.lastPathComponent, ".lease")
            XCTAssertEqual(preview.url.deletingLastPathComponent().lastPathComponent, "payload")
            XCTAssertEqual(try Data(contentsOf: preview.url), data)
            let active = try await FilePreview.reclaimAbandoned(in: root)
            XCTAssertEqual(active.inUse, 1); XCTAssertEqual(active.removed, 0)
            try await preview.close()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
            try await remote.remove(target, directory: false); try await remote.remove(folder, directory: true)
        }
    }
    func testRemotePreviewVerifiedSnapshotAndIdempotentCloseForEveryProtocol() async throws {
        for kind in TransferProtocol.allCases {
            let remote = try client(kind), root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = "/preview-\(UUID()) 中文.txt"
            let data = Data("Preview UTF-8 中文\n".utf8); try data.write(to: source)
            try await remote.upload(source, to: target)
            let preview = try await FilePreview.open(.remote(remote, target), temporaryParent: root)
            XCTAssertEqual(preview.url.lastPathComponent, URL(fileURLWithPath: target).lastPathComponent)
            XCTAssertEqual(preview.byteCount, Int64(data.count)); XCTAssertEqual(try Data(contentsOf: preview.url), data)
            let directory = try XCTUnwrap(preview.directory)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("journal").path).isEmpty)
            try await preview.close(); try await preview.close()
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            try await remote.remove(target, directory: false)
        }
    }
    func testRemotePreviewLimitRejectsBeforeCreatingSnapshotForEveryProtocol() async throws {
        for kind in TransferProtocol.allCases {
            let remote = try client(kind), root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = "/preview-limit-\(UUID())"
            try Data(repeating: 4, count: 1024).write(to: source); try await remote.upload(source, to: target)
            do {
                _ = try await FilePreview.open(.remote(remote, target), maximumRemoteBytes: 32, temporaryParent: root)
                XCTFail("Oversized preview must reject")
            } catch FilePreviewError.tooLarge { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
            try await remote.remove(target, directory: false)
        }
    }
    func testCancelledRemotePreviewRemovesEntireSnapshotForEveryProtocol() async throws {
        for kind in TransferProtocol.allCases {
            let remote = try client(kind), root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = "/preview-cancel-\(UUID())"
            try Data(repeating: 4, count: 512 * 1024).write(to: source); try await remote.upload(source, to: target)
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials,
                                    rateLimit: 64 * 1024, certificateAuthority: remote.certificateAuthority)
            let started = expectation(description: "Preview payload started"), recorder = PreviewProgress(started)
            let task = Task { try await FilePreview.open(.remote(slow, target), temporaryParent: root) { recorder.receive($0) } }
            await fulfillment(of: [started], timeout: 8); task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled preview must not publish a file") }
            catch is CancellationError { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
            try await remote.remove(target, directory: false)
        }
    }
}
