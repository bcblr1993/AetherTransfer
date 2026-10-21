import XCTest
@testable import AetherTransferCore

final class TabSessionTests: XCTestCase {
    func testTabSessionCreationAndSwitching() {
        var manager = TabSessionManager(initialLocalPath: "/Users/test")
        XCTAssertEqual(manager.tabs.count, 1)
        let tab1 = manager.activeTab
        XCTAssertEqual(tab1?.localPath, "/Users/test")
        XCTAssertEqual(tab1?.remotePath, "/")

        let tab2Id = manager.createTab(title: "Tab 2", localPath: "/Users/test/Downloads", remotePath: "/var/www")
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.activeTabId, tab2Id)
        XCTAssertEqual(manager.activeTab?.localPath, "/Users/test/Downloads")
        XCTAssertEqual(manager.activeTab?.remotePath, "/var/www")

        // Switch back to tab 1
        manager.selectTab(tab1!.id)
        XCTAssertEqual(manager.activeTabId, tab1!.id)
    }

    func testClosingTabsPreservesAtLeastOneTab() {
        var manager = TabSessionManager(initialLocalPath: "/Users/test")
        let tab2Id = manager.createTab(title: "Tab 2", localPath: "/Users/test", remotePath: "/")
        XCTAssertEqual(manager.tabs.count, 2)

        // Close active tab 2
        manager.closeTab(id: tab2Id)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotEqual(manager.activeTabId, tab2Id)

        // Attempting to close the last remaining tab resets it rather than having 0 tabs
        let lastId = manager.activeTabId
        manager.closeTab(id: lastId)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.activeTab)
    }
}
