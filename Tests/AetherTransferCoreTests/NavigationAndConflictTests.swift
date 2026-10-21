import XCTest
@testable import AetherTransferCore

final class NavigationAndConflictTests: XCTestCase {
    func testNavigationHistoryBackAndForward() {
        var history = NavigationHistory(initialPath: "/Users/test")
        XCTAssertEqual(history.currentPath, "/Users/test")
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.navigateTo("/Users/test/Documents")
        XCTAssertEqual(history.currentPath, "/Users/test/Documents")
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        history.navigateTo("/Users/test/Downloads")
        XCTAssertEqual(history.currentPath, "/Users/test/Downloads")

        // Go back
        XCTAssertTrue(history.goBack())
        XCTAssertEqual(history.currentPath, "/Users/test/Documents")
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        XCTAssertTrue(history.goBack())
        XCTAssertEqual(history.currentPath, "/Users/test")
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        // Cannot go back further
        XCTAssertFalse(history.goBack())
        XCTAssertEqual(history.currentPath, "/Users/test")

        // Go forward
        XCTAssertTrue(history.goForward())
        XCTAssertEqual(history.currentPath, "/Users/test/Documents")

        // Navigating to a new path truncates forward history
        history.navigateTo("/Users/test/Pictures")
        XCTAssertEqual(history.currentPath, "/Users/test/Pictures")
        XCTAssertFalse(history.canGoForward)
        XCTAssertTrue(history.canGoBack)
    }

    func testBreadcrumbComponents() {
        let breadcrumbs = RemotePath.breadcrumbs(for: "/var/log/nginx/access.log")
        XCTAssertEqual(breadcrumbs.count, 5)
        XCTAssertEqual(breadcrumbs[0], BreadcrumbItem(name: "/", path: "/"))
        XCTAssertEqual(breadcrumbs[1], BreadcrumbItem(name: "var", path: "/var"))
        XCTAssertEqual(breadcrumbs[2], BreadcrumbItem(name: "log", path: "/var/log"))
        XCTAssertEqual(breadcrumbs[3], BreadcrumbItem(name: "nginx", path: "/var/log/nginx"))
        XCTAssertEqual(breadcrumbs[4], BreadcrumbItem(name: "access.log", path: "/var/log/nginx/access.log"))

        let rootBreadcrumbs = RemotePath.breadcrumbs(for: "/")
        XCTAssertEqual(rootBreadcrumbs.count, 1)
        XCTAssertEqual(rootBreadcrumbs[0], BreadcrumbItem(name: "/", path: "/"))
    }

    func testConflictAutoRename() {
        let existing = ["file.txt", "file (1).txt", "image.png"]
        let unique1 = RemotePath.uniqueName(for: "file.txt", existingNames: existing)
        XCTAssertEqual(unique1, "file (2).txt")

        let unique2 = RemotePath.uniqueName(for: "other.txt", existingNames: existing)
        XCTAssertEqual(unique2, "other.txt")

        let unique3 = RemotePath.uniqueName(for: "image.png", existingNames: existing)
        XCTAssertEqual(unique3, "image (1).png")
    }
}
