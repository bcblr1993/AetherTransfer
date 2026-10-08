import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    func testPastePlanReadOnlyMetadataAndRevalidationForEveryProtocol() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .ftpes, .ftps, .webdav, .webdavs] {
            let remote = try client(kind)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-paste-protocol-\(UUID())")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: local) }
            let seed = local.appendingPathComponent("seed"), proof = local.appendingPathComponent("proof")
            let a = "/paste-source-\(UUID())", b = "/paste-target-\(UUID())"
            for path in [a, b, a + "/folder", a + "/folder/empty", b + "/folder"] { try await remote.mkdir(path) }
            let source = Data("source".utf8), target = Data("target".utf8)
            try source.write(to: seed)
            for path in [a + "/folder/file", a + "/folder/.hidden"] { try await remote.upload(seed, to: path) }
            try Data().write(to: seed); try await remote.upload(seed, to: a + "/folder/zero")
            try target.write(to: seed)
            for path in [b + "/folder/file", b + "/folder/extra"] { try await remote.upload(seed, to: path) }
            let selection = [FilePasteInput(root: .remote(remote, a), name: "folder")]
            let plan = try await FilePaste.preview(selection, destination: .remote(remote, b), move: true, policy: .overwrite)
            XCTAssertTrue(plan.canApply); XCTAssertEqual(plan.count, 5); XCTAssertEqual(plan.bytes, 12); XCTAssertEqual(plan.overwriteCount, 1)
            try await FilePaste.validate(plan)
            let unchanged = try await remote.list(b + "/folder", includingHidden: true)
            XCTAssertEqual(Set(unchanged.map(\.name)), ["file", "extra"])
            try await remote.download(b + "/folder/file", to: proof)
            XCTAssertEqual(try Data(contentsOf: proof), target)
            try await remote.download(a + "/folder/.hidden", to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), source)
            let localPlan = try await FilePaste.preview(selection, destination: .local(local))
            XCTAssertTrue(localPlan.canApply); try await FilePaste.validate(localPlan)
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("folder").path))
            let uploadPlan = try await FilePaste.preview([FilePasteInput(root: .local(local), name: "seed")], destination: .remote(remote, b))
            XCTAssertTrue(uploadPlan.canApply); try await FilePaste.validate(uploadPlan)
            try Data("changed source size".utf8).write(to: seed)
            try await remote.upload(seed, to: a + "/folder/.hidden", overwrite: true)
            do { try await FilePaste.validate(plan); XCTFail("Changed hidden source metadata must invalidate") }
            catch FilePasteError.changed { }
            for path in [a + "/folder/file", a + "/folder/.hidden", a + "/folder/zero", b + "/folder/file", b + "/folder/extra"] {
                try await remote.remove(path, directory: false)
            }
            for path in [a + "/folder/empty", a + "/folder", b + "/folder", a, b] { try await remote.remove(path, directory: true) }
        }
    }
    func testPastePlanOverlapDuplicateAndStaleDestinationForEveryProtocol() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .ftpes, .ftps, .webdav, .webdavs] {
            let remote = try client(kind)
            let seed = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-paste-seed-\(UUID())")
            try Data("seed".utf8).write(to: seed); defer { try? FileManager.default.removeItem(at: seed) }
            let a = "/paste-overlap-\(UUID())", b = "/paste-arrival-\(UUID())"
            for path in [a, b, a + "/folder", a + "/folder/sub"] { try await remote.mkdir(path) }
            try await remote.upload(seed, to: a + "/file")
            let folder = FilePasteInput(root: .remote(remote, a), name: "folder")
            let overlap = try await FilePaste.preview([folder], destination: .remote(remote, a + "/folder/sub"))
            XCTAssertFalse(overlap.canApply); XCTAssertEqual(overlap.items[0].issue, .overlap)
            let duplicate = try await FilePaste.preview([folder], destination: .remote(remote, a), policy: .keepBoth)
            XCTAssertTrue(duplicate.canApply); XCTAssertEqual(duplicate.items[0].destinationName, "folder (2)")
            try await FilePaste.validate(duplicate)
            let file = FilePasteInput(root: .remote(remote, a), name: "file")
            let plan = try await FilePaste.preview([file], destination: .remote(remote, b))
            try await remote.upload(seed, to: b + "/.arrival")
            do { try await FilePaste.validate(plan); XCTFail("New hidden target sibling must invalidate") }
            catch FilePasteError.changed { }
            let target = try await remote.list(b, includingHidden: true)
            XCTAssertEqual(target.map(\.name), [".arrival"])
            try await remote.remove(a + "/file", directory: false); try await remote.remove(b + "/.arrival", directory: false)
            for path in [a + "/folder/sub", a + "/folder", a, b] { try await remote.remove(path, directory: true) }
        }
    }
}
