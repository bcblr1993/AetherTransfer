import XCTest
@testable import AetherTransferCore

final class FileSortingTests: XCTestCase {
    func testFileSortingByNameSizeAndDate() {
        let now = Date()
        let fileA = FileEntry(name: "alpha.txt", path: "/alpha.txt", isDirectory: false, size: 500, modified: now.addingTimeInterval(-100))
        let fileB = FileEntry(name: "beta.jpg", path: "/beta.jpg", isDirectory: false, size: 200, modified: now)
        let fileC = FileEntry(name: "gamma.txt", path: "/gamma.txt", isDirectory: false, size: 1000, modified: now.addingTimeInterval(-200))
        let folder1 = FileEntry(name: "zeta_folder", path: "/zeta_folder", isDirectory: true, size: 0, modified: now.addingTimeInterval(-50))
        let folder2 = FileEntry(name: "alpha_folder", path: "/alpha_folder", isDirectory: true, size: 0, modified: now)

        let all = [fileA, folder1, fileB, folder2, fileC]

        // Default sort (Folders first, then Name ascending)
        let sortedDefault = FileEntry.sorted(all, by: .name, ascending: true, foldersFirst: true)
        XCTAssertEqual(sortedDefault.map(\.name), ["alpha_folder", "zeta_folder", "alpha.txt", "beta.jpg", "gamma.txt"])

        // Name descending (Folders still first)
        let sortedNameDesc = FileEntry.sorted(all, by: .name, ascending: false, foldersFirst: true)
        XCTAssertEqual(sortedNameDesc.map(\.name), ["zeta_folder", "alpha_folder", "gamma.txt", "beta.jpg", "alpha.txt"])

        // Size ascending
        let sortedSize = FileEntry.sorted(all, by: .size, ascending: true, foldersFirst: true)
        XCTAssertEqual(sortedSize.map(\.name), ["alpha_folder", "zeta_folder", "beta.jpg", "alpha.txt", "gamma.txt"])

        // Size descending
        let sortedSizeDesc = FileEntry.sorted(all, by: .size, ascending: false, foldersFirst: true)
        XCTAssertEqual(sortedSizeDesc.map(\.name), ["zeta_folder", "alpha_folder", "gamma.txt", "alpha.txt", "beta.jpg"])

        // Date descending (newest first)
        let sortedDateDesc = FileEntry.sorted(all, by: .date, ascending: false, foldersFirst: true)
        XCTAssertEqual(sortedDateDesc.map(\.name), ["alpha_folder", "zeta_folder", "beta.jpg", "alpha.txt", "gamma.txt"])
    }

    func testFileEntryKindExtension() {
        let textFile = FileEntry(name: "document.pdf", path: "/document.pdf", isDirectory: false)
        XCTAssertEqual(textFile.fileExtension, "pdf")
        XCTAssertEqual(textFile.kindDescription, "PDF 文稿")

        let folder = FileEntry(name: "Photos", path: "/Photos", isDirectory: true)
        XCTAssertEqual(folder.fileExtension, "")
        XCTAssertEqual(folder.kindDescription, "文件夹")
    }
}
