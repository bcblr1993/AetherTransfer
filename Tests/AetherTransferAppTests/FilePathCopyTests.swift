import AppKit
import AetherTransferCore
import XCTest
@testable import AetherTransferApp

@MainActor final class FilePathCopyTests: XCTestCase {
    func testPlainPathCopyPreservesRawS3KeysAndReplacesPreviousPayload() {
        let board = NSPasteboard(name: .init("aethertransfer-copy-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("old payload", forType: .html)
        let entries = [FileEntry(name: "中文 #.txt", path: "/folder/中文 #.txt", isDirectory: false),
                       FileEntry(name: ".hidden", path: "display path", isDirectory: false, s3Key: "raw//./中文/.hidden")]
        XCTAssertTrue(FilePathCopy.write(entries, to: board))
        XCTAssertEqual(board.string(forType: .string), "/folder/中文 #.txt\nraw//./中文/.hidden")
        let textTypes = Set([NSPasteboard.PasteboardType.string, .init("NSStringPboardType")])
        XCTAssertTrue(Set(board.types ?? []).isSubset(of: textTypes), "Only text and AppKit's legacy text alias are allowed")
        XCTAssertNil(board.string(forType: .fileURL)); XCTAssertNil(board.string(forType: .html))
        XCTAssertFalse(FilePathCopy.write([], to: board))
        XCTAssertEqual(board.string(forType: .string), "/folder/中文 #.txt\nraw//./中文/.hidden")
    }
    func testCopyMenuValidationUsesCurrentSelectionAndEnabledState() {
        let table = BrowserTable(), grid = BrowserIconGrid()
        let entry = FileEntry(name: "file", path: "/file", isDirectory: false)
        let item = NSMenuItem(title: "Copy", action: #selector(BrowserTable.copy(_:)), keyEquivalent: "c")
        var current: [FileEntry] = []
        var collections = 0
        table.copyEntries = { collections += 1; return current }; grid.copyEntries = { collections += 1; return current }
        table.hasCopySelection = { !current.isEmpty }; grid.hasCopySelection = { !current.isEmpty }
        XCTAssertFalse(table.validateUserInterfaceItem(item)); XCTAssertFalse(grid.validateUserInterfaceItem(item))
        current = [entry]
        XCTAssertTrue(table.validateUserInterfaceItem(item)); XCTAssertTrue(grid.validateUserInterfaceItem(item))
        table.isEnabled = false; grid.isEnabled = false
        XCTAssertFalse(table.validateUserInterfaceItem(item)); XCTAssertFalse(grid.validateUserInterfaceItem(item))
        table.isEnabled = true; grid.isEnabled = true; current = []
        XCTAssertFalse(table.validateUserInterfaceItem(item)); XCTAssertFalse(grid.validateUserInterfaceItem(item))
        XCTAssertEqual(collections, 0, "Menu validation must not repeatedly materialize large selections")
    }
}
