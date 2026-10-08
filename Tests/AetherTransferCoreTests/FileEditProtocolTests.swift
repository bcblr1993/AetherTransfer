import Foundation
import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    func testTextEditingRoundTripExternalSaveAndContentConflictForEveryProtocol() async throws {
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-edit-protocol-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let local = root.appendingPathComponent("source"), proof = root.appendingPathComponent("proof")
            let path = "/编辑 \(UUID().uuidString) #.txt"
            try Data("original\r\n中文\r\n".utf8).write(to: local); try await remote.upload(local, to: path)
            let session = try await FileEditSession.open(.remote(remote, path))
            defer { try? FileManager.default.removeItem(at: session.directory) }
            let snapshot = try await session.snapshot(); XCTAssertEqual(snapshot.text, "original\r\n中文\r\n")
            _ = try await session.save(text: "内置保存\n")
            try await remote.download(path, to: proof)
            XCTAssertEqual(try Data(contentsOf: proof), Data("内置保存\n".utf8))
            try Data("external save\n".utf8).write(to: session.draftURL, options: .atomic)
            _ = try await session.save()
            try await remote.download(path, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), Data("external save\n".utf8))
            try Data("another saved\n".utf8).write(to: local); try await remote.upload(local, to: path, overwrite: true)
            do { _ = try await session.save(text: "my pending draft"); XCTFail("\(kind) must refuse changed source") }
            catch FileEditError.changed { }
            try await remote.download(path, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), Data("another saved\n".utf8))
            let preserved = try await session.snapshot(); XCTAssertEqual(preserved.text, "my pending draft")
            let latest = try await session.reload(); XCTAssertEqual(latest.text, "another saved\n")
            _ = try await session.save(text: "merged save\n")
            try await remote.download(path, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), Data("merged save\n".utf8))
            try await session.close(); try await remote.remove(path, directory: false)
        }
    }
    func testBoundedDownloadsRejectOversizedBodiesAndPreserveOriginalForEveryProtocol() async throws {
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-edit-limit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            let path = "/limit-\(UUID().uuidString)"
            try Data(repeating: 65, count: 96 * 1024).write(to: source); try await remote.upload(source, to: path)
            try Data("original".utf8).write(to: target)
            do { try await remote.download(path, to: target, overwrite: true, maximumBytes: 32); XCTFail("Body limit must reject") }
            catch TransferError.remote { }
            XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
            try await remote.remove(path, directory: false)
        }
    }
    func testCancelledEditorSavePreservesSourceAndDraft() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .webdavs] {
            let remote = try client(kind)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-edit-cancel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let local = root.appendingPathComponent("source"), proof = root.appendingPathComponent("proof")
            let directory = "/editor-cancel-\(UUID().uuidString)", path = directory + "/file.txt"
            try await remote.mkdir(directory)
            try Data("original".utf8).write(to: local); try await remote.upload(local, to: path)
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, rateLimit: 64 * 1024,
                                    certificateAuthority: remote.certificateAuthority)
            let session = try await FileEditSession.open(.remote(slow, path))
            defer { try? FileManager.default.removeItem(at: session.directory) }
            let text = String(repeating: "x", count: 512 * 1024)
            let operation = Task { try await session.save(text: text) }
            var sending = false
            // Digest may drain the unauthenticated PUT before libcurl resends it.
            for _ in 0..<150 {
                if try await remote.list(directory).contains(where: { $0.name.hasSuffix(".part") && $0.size > 0 }) { sending = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            operation.cancel()
            do { _ = try await operation.value; XCTFail("Cancelled save must fail") }
            catch is CancellationError { }
            XCTAssertTrue(sending, "\(kind) cancellation must exercise a partially uploaded file")
            try await remote.download(path, to: proof)
            XCTAssertEqual(try Data(contentsOf: proof), Data("original".utf8))
            let draft = try await session.snapshot(); XCTAssertEqual(draft.text, text)
            let listing = try await remote.list(directory); XCTAssertEqual(listing.map(\.name), ["file.txt"])
            try await session.close()
            if kind == .ftp {
                // Cancel only after the editor's private download has actually received bytes.
                try Data(text.utf8).write(to: local); try await remote.upload(local, to: path, overwrite: true)
                let fm = FileManager.default, temporary = fm.temporaryDirectory
                let before = Set(try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil))
                let opening = Task { try await FileEditSession.open(.remote(slow, path)) }
                var pendingDirectory: URL?
                for _ in 0..<100 {
                    let current = Set(try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil))
                    for candidate in current.subtracting(before) where candidate.lastPathComponent.hasPrefix("aethertransfer-edit-") {
                        let files = (try? fm.contentsOfDirectory(at: candidate.appendingPathComponent("work"), includingPropertiesForKeys: [.fileSizeKey])) ?? []
                        if files.contains(where: { $0.pathExtension == "part" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }) {
                            pendingDirectory = candidate; break
                        }
                    }
                    if pendingDirectory != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                opening.cancel()
                do { let opened = try await opening.value; try await opened.close(); XCTFail("Cancelled open must fail") }
                catch is CancellationError { }
                XCTAssertNotNil(pendingDirectory, "Cancellation must exercise a partially downloaded editor file")
                if let pendingDirectory { XCTAssertFalse(fm.fileExists(atPath: pendingDirectory.path), "Cancelled open must clean its own private directory") }
                try await remote.download(path, to: proof, overwrite: true)
                XCTAssertEqual(try Data(contentsOf: proof), Data(text.utf8))
            }
            try await remote.remove(path, directory: false); try await remote.remove(directory, directory: true)
        }
    }
}
