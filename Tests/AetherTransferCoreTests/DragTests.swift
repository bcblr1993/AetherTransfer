import XCTest
@testable import AetherTransferCore

final class DragTests: XCTestCase {
    func testDraggedFileCodableRoundTrip() throws {
        let profileID = UUID()
        let original = DraggedFile(
            remote: true,
            profileID: profileID,
            path: "/var/data/report.pdf",
            name: "report.pdf",
            isDirectory: false,
            size: 1048576
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DraggedFile.self, from: data)

        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.remote, true)
        XCTAssertEqual(decoded.profileID, profileID)
        XCTAssertEqual(decoded.path, "/var/data/report.pdf")
        XCTAssertEqual(decoded.name, "report.pdf")
        XCTAssertFalse(decoded.isDirectory)
        XCTAssertEqual(decoded.size, 1048576)

        let entry = decoded.entry
        XCTAssertEqual(entry.name, "report.pdf")
        XCTAssertEqual(entry.path, "/var/data/report.pdf")
        XCTAssertFalse(entry.isDirectory)
        XCTAssertEqual(entry.size, 1048576)
    }

    func testDragPathHelperRelativeSubpath() {
        // Nested files
        XCTAssertEqual(
            DragPathHelper.relativeSubpath(base: "/var/www", child: "/var/www/site/index.html"),
            "site/index.html"
        )
        // Root base
        XCTAssertEqual(
            DragPathHelper.relativeSubpath(base: "/", child: "/etc/nginx/nginx.conf"),
            "etc/nginx/nginx.conf"
        )
        // Trailing slashes
        XCTAssertEqual(
            DragPathHelper.relativeSubpath(base: "/home/user/", child: "/home/user/docs/file.pdf"),
            "docs/file.pdf"
        )
        // Deeply nested subdirectories
        XCTAssertEqual(
            DragPathHelper.relativeSubpath(base: "/data", child: "/data/a/b/c/d.txt"),
            "a/b/c/d.txt"
        )
        // Identical paths should return nil
        XCTAssertNil(DragPathHelper.relativeSubpath(base: "/var/www", child: "/var/www"))
        XCTAssertNil(DragPathHelper.relativeSubpath(base: "/var/www/", child: "/var/www"))
    }

    func testDragExportSessionDeduplicatesConcurrentRequests() async throws {
        let session = DragExportSession()
        final class Counter: @unchecked Sendable {
            var value = 0
            let lock = NSLock()
            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }
        }
        let counter = Counter()
        let expectedURL = URL(fileURLWithPath: "/tmp/sample_drag_test.txt")

        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await session.export {
                        counter.increment()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return expectedURL
                    }
                }
            }
            var urls: [URL] = []
            for try await url in group {
                urls.append(url)
            }
            return urls
        }

        XCTAssertEqual(results.count, 10)
        for url in results {
            XCTAssertEqual(url, expectedURL)
        }
        XCTAssertEqual(counter.value, 1, "The export closure must be executed exactly once despite 10 concurrent requests")
    }

    func testDragExportSessionPropagatesErrors() async {
        let session = DragExportSession()
        struct DummyError: Error, Equatable {}

        do {
            _ = try await session.export {
                throw DummyError()
            }
            XCTFail("Should have thrown DummyError")
        } catch let err as DummyError {
            XCTAssertEqual(err, DummyError())
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
