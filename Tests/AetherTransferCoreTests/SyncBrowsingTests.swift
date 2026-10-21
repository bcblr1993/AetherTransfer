import XCTest
@testable import AetherTransferCore

final class SyncBrowsingTests: XCTestCase {
    func testSynchronizedBrowsingPathMapping() {
        let localBase = "/Users/chenxu/Projects/MyApp"
        let remoteBase = "/var/www/html/MyApp"

        var manager = SyncNavigationManager(localRoot: localBase, remoteRoot: remoteBase, isEnabled: true)
        XCTAssertTrue(manager.isEnabled)

        // 1. Local navigates deeper
        let localNew = "/Users/chenxu/Projects/MyApp/assets/images"
        let remoteTarget = manager.remotePathForLocalNavigation(to: localNew)
        XCTAssertEqual(remoteTarget, "/var/www/html/MyApp/assets/images")

        // 2. Remote navigates deeper
        let remoteNew = "/var/www/html/MyApp/docs/v1"
        let localTarget = manager.localPathForRemoteNavigation(to: remoteNew)
        XCTAssertEqual(localTarget, "/Users/chenxu/Projects/MyApp/docs/v1")

        // 3. Navigation to root
        XCTAssertEqual(manager.remotePathForLocalNavigation(to: localBase), remoteBase)
        XCTAssertEqual(manager.localPathForRemoteNavigation(to: remoteBase), localBase)

        // 4. When disabled, returns nil
        manager.isEnabled = false
        XCTAssertNil(manager.remotePathForLocalNavigation(to: localNew))
        XCTAssertNil(manager.localPathForRemoteNavigation(to: remoteNew))
    }
}
