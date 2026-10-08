import XCTest
@testable import AetherTransferCore

final class WebDAVListingTests: XCTestCase {
    private let origin = "https://example.test:8443/dav/"
    private func response(_ href: String, collection: Bool = false, size: String = "24", status: Int = 200) -> String {
        """
        <x:response><x:href>\(href)</x:href><x:propstat><x:prop>
        <x:resourcetype>\(collection ? "<x:collection/>" : "")</x:resourcetype>
        <x:getcontentlength>\(size)</x:getcontentlength><x:getlastmodified>Wed, 07 Oct 2026 10:30:00 GMT</x:getlastmodified>
        </x:prop><x:status>HTTP/1.1 \(status) Status</x:status></x:propstat></x:response>
        """
    }
    private func document(_ children: String) -> String {
        "<x:multistatus xmlns:x=\"DAV:\">" + response("/dav/", collection: true) + children + "</x:multistatus>"
    }
    func testNamespacePropertiesUnicodeAndCollectionRoot() throws {
        let xml = document(response("https://example.test:8443/dav/%E4%B8%AD%E6%96%87%20%23.txt") +
                           response("nested/", collection: true) + response("empty", size: "0"))
        let entries = try WebDAVListing.parse(xml, parent: "/dav", origin: origin)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].path, "/dav/nested")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries.first { $0.name == "中文 #.txt" }?.size, 24)
        XCTAssertEqual(entries.first { $0.name == "empty" }?.size, 0)
        XCTAssertNotNil(entries.first?.modified)
        let invalidDate = document(response("bad-date")).replacingOccurrences(of: "07 Oct 2026", with: "31 Feb 2026")
        XCTAssertNil(try WebDAVListing.parse(invalidDate, parent: "/dav", origin: origin).first?.modified)
        let mixed = document(response("a").replacingOccurrences(of: "</x:response>", with:
            "<x:propstat><x:prop><x:getcontentlength>999</x:getcontentlength></x:prop><x:status>HTTP/1.1 404 Not Found</x:status></x:propstat></x:response>"))
        XCTAssertEqual(try WebDAVListing.parse(mixed, parent: "/dav", origin: origin).first?.size, 24)
    }
    func testRejectsUnsafeHrefsIncompleteResultsAndEntities() {
        for href in ["https://elsewhere.test:8443/dav/a", "http://example.test:8443/dav/a", "//elsewhere.test/dav/a",
                     "/dav/../outside", "/dav/%2e%2e/outside", "/dav/a%2Fb", "/dav/a%00b", "/dav/a%5Cb",
                     "/dav/deeper/a", "/else/a", "/dav/a?query=1", "/dav/a#fragment", "https://u:p@example.test:8443/dav/a"] {
            XCTAssertThrowsError(try WebDAVListing.parse(document(response(href)), parent: "/dav", origin: origin), href)
        }
        for xml in [document(response("a", status: 403)), document(response("a", size: "-1")),
                    document(response("a") + response("a")), "<x:multistatus xmlns:x=\"DAV:\"/>",
                    document(response("a")).replacingOccurrences(of: "HTTP/1.1 200 Status", with: "bad status"),
                    "<!DOCTYPE x [<!ENTITY leak SYSTEM 'file:///private/etc/passwd'>]>" + document(response("a")),
                    "<!doCTyPe x [<!ENTITY leak SYSTEM 'file:///private/etc/passwd'>]>" + document(response("a")),
                    document(response("a")).replacingOccurrences(of: "DAV:", with: "other:") ] {
            XCTAssertThrowsError(try WebDAVListing.parse(xml, parent: "/dav", origin: origin))
        }
        let deep = document(String(repeating: "<x:unknown>", count: 50) + String(repeating: "</x:unknown>", count: 50))
        XCTAssertThrowsError(try WebDAVListing.parse(deep, parent: "/dav", origin: origin))
    }
    func testWebDAVURLsHaveSingleSlashAndPersistProtocol() throws {
        for kind in [TransferProtocol.webdav, .webdavs] {
            let profile = ServerProfile(host: "example.test", port: kind.defaultPort, username: "fixture", protocolKind: kind)
            XCTAssertEqual(try profile.url(path: "/dav/中文/a b#%.txt"),
                           "\(kind.urlScheme)://example.test:\(kind.defaultPort)/dav/%E4%B8%AD%E6%96%87/a%20b%23%25.txt")
            XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile)), profile)
        }
    }
}
