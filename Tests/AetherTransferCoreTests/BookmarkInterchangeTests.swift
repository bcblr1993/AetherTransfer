import XCTest
@testable import AetherTransferCore

final class BookmarkInterchangeTests: XCTestCase {
    func testExportAndImportBookmarksJSON() throws {
        let profile1 = ServerProfile(
            name: "Production Web",
            group: "Web",
            host: "web.example.com",
            port: 22,
            username: "deploy",
            protocolKind: .sftp,
            initialPath: "/var/www/html"
        )
        let profile2 = ServerProfile(
            name: "Internal FTP",
            group: "Internal",
            host: "ftp.lan",
            port: 21,
            username: "ftpuser",
            protocolKind: .ftp,
            initialPath: "/public"
        )

        let original = [profile1, profile2]
        let data = try ServerProfile.exportJSON(original)
        XCTAssertFalse(data.isEmpty)

        // Verify JSON string is valid and doesn't contain secrets
        let jsonStr = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonStr.contains("web.example.com"))
        XCTAssertTrue(jsonStr.contains("Production Web"))
        XCTAssertFalse(jsonStr.contains("password"))

        // Import back
        let imported = try ServerProfile.importJSON(data)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0].name, "Production Web")
        XCTAssertEqual(imported[0].host, "web.example.com")
        XCTAssertEqual(imported[0].protocolKind, .sftp)
        XCTAssertEqual(imported[1].name, "Internal FTP")
        XCTAssertEqual(imported[1].host, "ftp.lan")
        XCTAssertEqual(imported[1].protocolKind, .ftp)
    }

    func testImportRejectsMalformedJSON() {
        let invalidData = "This is not JSON".data(using: .utf8)!
        XCTAssertThrowsError(try ServerProfile.importJSON(invalidData))
    }
}
