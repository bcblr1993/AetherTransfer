import XCTest
@testable import AetherTransferCore

final class FileColumnHistoryTests: XCTestCase {
    private func directory(_ path: String) -> FileEntry {
        FileEntry(name: path, path: path, isDirectory: true)
    }
    func testNavigationAndRefreshRemoveObsoleteDescendants() {
        var history = FileColumnHistory()
        let root = FileColumnSnapshot(path: "/", files: [directory("/a"), directory("/b")])
        history.accept(root)
        history.accept(FileColumnSnapshot(path: "/a", files: [directory("/a/deep")]))
        history.accept(FileColumnSnapshot(path: "/a/deep", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/", "/a", "/a/deep"])
        XCTAssertEqual(history.branchSelection(at: 0), ["/a"])
        XCTAssertEqual(history.branchSelection(at: 1), ["/a/deep"])
        XCTAssertTrue(history.branchSelection(at: 2).isEmpty)
        XCTAssertTrue(history.branchSelection(at: -1).isEmpty)
        history.accept(root)
        history.accept(FileColumnSnapshot(path: "/b", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/", "/b"])
        // A refreshed parent that lost its child cannot leave a stale child column.
        history.accept(FileColumnSnapshot(path: "/", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/"])
    }
    func testPathJumpAndFileDoNotCreateAncestry() {
        var history = FileColumnHistory()
        history.accept(FileColumnSnapshot(path: "/", files: [FileEntry(name: "file", path: "/file", isDirectory: false)]))
        history.accept(FileColumnSnapshot(path: "/file", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/file"])
        history.accept(FileColumnSnapshot(path: "/elsewhere", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/elsewhere"])
    }
    func testS3PrefixIdentityAndBranchesUseOriginalUTF8() {
        let composed = "café/", decomposed = "cafe\u{301}/"
        var history = FileColumnHistory()
        let root = FileColumnSnapshot(path: "", files: [
            FileEntry(name: composed, path: composed, isDirectory: true, s3Key: composed),
            FileEntry(name: decomposed, path: decomposed, isDirectory: true, s3Key: decomposed)
        ])
        history.accept(root)
        history.accept(FileColumnSnapshot(path: decomposed, files: []))
        XCTAssertEqual(history.branchSelection(at: 0), [root.files[1].id])
        XCTAssertNotEqual(FileColumnSnapshot(path: composed, files: []).id, history.columns[1].id)
        history.accept(FileColumnSnapshot(path: composed, files: []))
        // This is a sibling jump, not a Unicode-equivalent refresh.
        XCTAssertEqual(history.columns.count, 1)
        XCTAssertEqual(Data(history.columns[0].path.utf8), Data(composed.utf8))
        history.accept(FileColumnSnapshot(path: "//literal/", files: []))
        XCTAssertEqual(history.columns[0].path, "//literal/")
    }
    func testDepthEvictsOldColumnsWithoutDroppingCurrentEntries() {
        var history = FileColumnHistory()
        for index in 0..<40 {
            history.accept(FileColumnSnapshot(path: "/\(index)", files: [directory("/\(index + 1)")]))
        }
        XCTAssertEqual(history.columns.count, FileColumnHistory.maximumColumns)
        XCTAssertEqual(history.columns.last?.path, "/39")
        XCTAssertEqual(history.columns.last?.files.count, 1)
    }
    func testAncestorRowAndMetadataBudgetsRetainEntireCurrentListing() {
        var history = FileColumnHistory()
        let rows = (0..<50_001).map { FileEntry(name: "file\($0)", path: "/file\($0)", isDirectory: false) }
        history.accept(FileColumnSnapshot(path: "/", files: rows + [directory("/child")]))
        XCTAssertEqual(history.columns[0].files.count, 50_002)
        history.accept(FileColumnSnapshot(path: "/child", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/child"])
        let longNames = (0..<6_000).map { FileEntry(name: String(repeating: "名", count: 1_024), path: "/\($0)", isDirectory: false) }
        let heavy = FileColumnSnapshot(path: "/heavy", files: longNames + [directory("/heavy/child")])
        XCTAssertGreaterThan(heavy.estimatedBytes, FileColumnHistory.maximumAncestorBytes)
        history.accept(heavy)
        history.accept(FileColumnSnapshot(path: "/heavy/child", files: []))
        XCTAssertEqual(history.columns.map(\.path), ["/heavy/child"])
    }
}
