import XCTest
@testable import AetherTransferCore

final class CoreTests: XCTestCase {
    func testAbsoluteFTPAndSFTPPathsEscapeNames() throws {
        var profile = ServerProfile(host: "localhost", username: "test")
        XCTAssertEqual(try profile.url(path: "/中文/a b#?.txt"), "sftp://localhost:22/%E4%B8%AD%E6%96%87/a%20b%23%3F.txt")
        profile.protocolKind = .ftp; profile.port = 21
        XCTAssertEqual(try profile.url(path: "/uploads", directory: true), "ftp://localhost:21//uploads/")
        profile.protocolKind = .ftpes
        XCTAssertEqual(profile.protocolKind.defaultPort, 21)
        XCTAssertEqual(try profile.url(path: "/uploads", directory: true), "ftp://localhost:21//uploads/")
        profile.protocolKind = .ftps; profile.port = 990
        XCTAssertEqual(try profile.url(path: "/uploads", directory: true), "ftps://localhost:990//uploads/")
    }
    func testPathRejectsCommandInjection() throws {
        for name in ["a\nb", "a\rb", "a\0b", "../x", ".", "", "a/b"] { XCTAssertThrowsError(try RemotePath.validateName(name)) }
        XCTAssertEqual(try RemotePath.join("/a/b", "空 格"), "/a/b/空 格")
        XCTAssertEqual(RemotePath.parent("/"), "/")
        XCTAssertEqual(RemotePath.normalize("/a/../b/./"), "/b")
    }
    func testListingPreservesSpacesUnicodeAndLinks() throws {
        let text = """
        drwxr-xr-x 2 owner group 4096 Oct 7 2026 folder with spaces
        -rw-r--r-- 1 owner group 24 Oct 7 10:30 中文 文件.txt
        lrwxrwxrwx 1 owner group 8 Oct 7 2026 linked -> /target
        drwxr-xr-x 2 owner group 4096 Oct 7 2026 .
        """
        let entries = try DirectoryListing.parse(text, parent: "/data")
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first?.name, "folder with spaces")
        XCTAssertTrue(entries.first?.isDirectory == true)
        XCTAssertTrue(entries.contains { $0.name == "中文 文件.txt" && $0.size == 24 })
        XCTAssertTrue(entries.contains { $0.name == "linked" && $0.isSymbolicLink })
        XCTAssertThrowsError(try DirectoryListing.parse("unrecognized directory response", parent: "/"))
        let dates = try DirectoryListing.parse("-rw-r--r-- 1 owner group 1 7 Oct 2026 day-first\n-rw-r--r-- 1 owner group 1 Feb 31 2026 invalid-date", parent: "/")
        XCTAssertNotNil(dates.first { $0.name == "day-first" }?.modified)
        XCTAssertNil(dates.first { $0.name == "invalid-date" }?.modified)
    }
    func testProfileStoreContainsNoSecrets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProfileStore(file: folder.appendingPathComponent("servers.json"))
        let profiles = [ServerProfile(name: "Fixture", host: "localhost", username: "test")]
        try store.save(profiles)
        XCTAssertEqual(try store.load(), profiles)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("passphrase"))
    }
    func testImportedProfilesDoNotAuthorizeKeysOrReplaceExistingProfiles() throws {
        let existing = ServerProfile(name: "Existing", host: "localhost", username: "test")
        var imported = existing
        imported.name = "Imported"; imported.trustedHostKey = "fake-host-key"; imported.privateKeyPath = "/a/private/key"
        let result = try ProfileStore.importing(JSONEncoder().encode([imported]), into: [existing])
        XCTAssertEqual(result.count, 2); XCTAssertEqual(result[0], existing)
        XCTAssertNotEqual(result[1].id, existing.id)
        XCTAssertNil(result[1].trustedHostKey); XCTAssertEqual(result[1].privateKeyPath, "")
        XCTAssertThrowsError(try ProfileStore.importing(JSONEncoder().encode([imported, imported]), into: []))
        XCTAssertThrowsError(try ProfileStore.importing(Data(repeating: 0, count: 1024 * 1024 + 1), into: []))
        imported.host = "invalid/host"
        XCTAssertThrowsError(try ProfileStore.importing(JSONEncoder().encode([imported]), into: []))
    }
    func testPresentationFiltersUnicodeHiddenFilesAndOrdersNumericValues() {
        let entries = [FileEntry(name: "文件 10", path: "/10", isDirectory: false, size: 10),
                       FileEntry(name: "文件 2", path: "/2", isDirectory: false, size: 2),
                       FileEntry(name: ".文件 1", path: "/1", isDirectory: false, size: 1)]
        XCTAssertEqual(FilePresentation.entries(entries, query: "文件", showHidden: false).map(\.name), ["文件 2", "文件 10"])
        XCTAssertEqual(FilePresentation.entries(entries, query: "", showHidden: true, field: .size, descending: true).map(\.size), [10, 2, 1])
        XCTAssertTrue(FilePresentation.entries(entries, query: "no match", showHidden: true).isEmpty)
    }
}
