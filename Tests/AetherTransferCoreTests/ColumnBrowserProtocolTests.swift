import Foundation
import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    func testColumnHistoryUsesRealHierarchicalListingsAcrossFileServers() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-column-seed-\(UUID())")
        try Data("column contents".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind), root = "/columns-\(UUID())", child = root + "/中文 + 空格"
            try await remote.mkdir(root); try await remote.mkdir(child)
            try await remote.upload(source, to: child + "/file.txt")
            var history = FileColumnHistory()
            let parent = FileColumnSnapshot(path: root, files: try await remote.list(root))
            let directory = try XCTUnwrap(parent.files.first { $0.isDirectory })
            XCTAssertEqual(directory.path, child)
            history.accept(parent)
            history.accept(FileColumnSnapshot(path: directory.path, files: try await remote.list(directory.path)))
            XCTAssertEqual(history.columns.map(\.path), [root, child])
            XCTAssertEqual(history.branchSelection(at: 0), [directory.id])
            XCTAssertEqual(history.columns.last?.files.map(\.path), [child + "/file.txt"])
            history.accept(parent)
            XCTAssertEqual(history.columns.count, 1)
            try await remote.remove(child + "/file.txt", directory: false)
            try await remote.remove(child, directory: true); try await remote.remove(root, directory: true)
        }
    }
}
