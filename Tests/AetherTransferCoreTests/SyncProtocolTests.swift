import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    func testSyncPreviewRoundTripAndExplicitMirrorForEveryProtocol() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .ftpes, .ftps] {
            let client = try client(kind)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-sync-protocol-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let local = directory.appendingPathComponent("source"), downloaded = directory.appendingPathComponent("downloaded")
            try FileManager.default.createDirectory(at: local.appendingPathComponent("中文 子目录"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: false)
            let data = Data(repeating: 79, count: 64 * 1024)
            try data.write(to: local.appendingPathComponent("中文 子目录/a #.txt"))
            try Data().write(to: local.appendingPathComponent("empty"))
            let orphanSource = directory.appendingPathComponent("orphan-source")
            try Data("keep unless selected".utf8).write(to: orphanSource)
            let remote = "/sync-\(UUID().uuidString)"
            try await client.mkdir(remote); try await client.upload(orphanSource, to: remote + "/orphan")
            var options = SyncOptions(); options.comparison = .contents; options.mirror = true
            let left = SyncRoot.local(local), right = SyncRoot.remote(client, remote)
            let preview = try await SyncEngine.preview(left: left, right: right, options: options)
            let initialFiles = try await client.list(remote)
            XCTAssertEqual(initialFiles.count, 1, "Preview must not mutate the remote directory")
            let selected = Set(preview.items.filter(\.selectedByDefault).map(\.id))
            XCTAssertFalse(selected.contains("orphan"))
            _ = try await SyncEngine.execute(preview, left: left, right: right, selected: selected)
            let first = try await client.list(remote)
            XCTAssertTrue(first.contains { $0.name == "orphan" })
            let mirror = try await SyncEngine.preview(left: left, right: right, options: options)
            XCTAssertEqual(mirror.items.map(\.path), ["orphan"])
            _ = try await SyncEngine.execute(mirror, left: left, right: right, selected: ["orphan"])
            let afterMirror = try await client.list(remote)
            XCTAssertFalse(afterMirror.contains { $0.name == "orphan" })
            options.mode = .rightToLeft; options.mirror = false
            let downloadLeft = SyncRoot.local(downloaded)
            let download = try await SyncEngine.preview(left: downloadLeft, right: right, options: options)
            _ = try await SyncEngine.execute(download, left: downloadLeft, right: right, selected: Set(download.items.filter(\.selectedByDefault).map(\.id)))
            XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("中文 子目录/a #.txt")), data)
            XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent("empty")).count, 0)
        }
    }
    func testRemoteToRemoteBidirectionalSyncAndStaleTargetRefusal() async throws {
        for kind in [TransferProtocol.ftp, .sftp] {
            let client = try client(kind)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-sync-bridge-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("source"), proof = directory.appendingPathComponent("proof")
            let a = "/sync-left-\(UUID().uuidString)", b = "/sync-right-\(UUID().uuidString)"
            try await client.mkdir(a); try await client.mkdir(b)
            try Data("AAA".utf8).write(to: source); try await client.upload(source, to: a + "/conflict")
            try await client.upload(source, to: a + "/left-only")
            try Data("BBB".utf8).write(to: source); try await client.upload(source, to: b + "/conflict")
            try await client.upload(source, to: b + "/right-only")
            var options = SyncOptions(); options.comparison = .contents; options.mode = .bidirectional
            let left = SyncRoot.remote(client, a), right = SyncRoot.remote(client, b)
            let preview = try await SyncEngine.preview(left: left, right: right, options: options)
            _ = try await SyncEngine.execute(preview, left: left, right: right, selected: Set(preview.items.filter(\.executable).map(\.id)), resolutions: ["conflict": .rightToLeft])
            try await client.download(a + "/conflict", to: proof)
            XCTAssertEqual(try Data(contentsOf: proof), Data("BBB".utf8))
            let aFiles = try await client.list(a), bFiles = try await client.list(b)
            XCTAssertEqual(Set(aFiles.map(\.name)), ["conflict", "left-only", "right-only"])
            XCTAssertEqual(Set(bFiles.map(\.name)), Set(aFiles.map(\.name)))
            try Data("AAA".utf8).write(to: source); try await client.upload(source, to: a + "/conflict", overwrite: true)
            options.mode = .leftToRight
            let stale = try await SyncEngine.preview(left: left, right: right, options: options)
            try Data("CCC".utf8).write(to: source); try await client.upload(source, to: b + "/conflict", overwrite: true)
            do { _ = try await SyncEngine.execute(stale, left: left, right: right, selected: ["conflict"]); XCTFail("A changed target must not be overwritten") }
            catch SyncError.changed { }
            try await client.download(b + "/conflict", to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), Data("CCC".utf8))
        }
    }
}
