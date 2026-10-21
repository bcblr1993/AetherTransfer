import XCTest
@testable import AetherTransferCore

final class ProfileAndPlacesTests: XCTestCase {
    func testProfileGrouping() {
        let p1 = ServerProfile(name: "Prod 1", group: "Production", host: "prod1.com", username: "admin")
        let p2 = ServerProfile(name: "Prod 2", group: "Production", host: "prod2.com", username: "admin")
        let p3 = ServerProfile(name: "Dev 1", group: "Development", host: "dev.com", username: "dev")
        let p4 = ServerProfile(name: "Ungrouped", group: "", host: "other.com", username: "root")

        let profiles = [p1, p2, p3, p4]
        let groups = ServerProfile.grouped(profiles)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].groupName, "Development")
        XCTAssertEqual(groups[0].profiles.map(\.name), ["Dev 1"])

        XCTAssertEqual(groups[1].groupName, "Production")
        XCTAssertEqual(groups[1].profiles.map(\.name), ["Prod 1", "Prod 2"])

        XCTAssertEqual(groups[2].groupName, "未分组")
        XCTAssertEqual(groups[2].profiles.map(\.name), ["Ungrouped"])
    }

    func testDefaultPlaces() {
        let places = PlaceItem.defaultPlaces()
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 名称随系统语言变化（CI 为英文），按路径核对并与当前语言的本地化名称比对
        let expected = [
            (home.path, L10n.tr("个人文件夹", "Home")),
            (home.appendingPathComponent("Desktop").path, L10n.tr("桌面", "Desktop")),
            (home.appendingPathComponent("Documents").path, L10n.tr("文稿", "Documents")),
            (home.appendingPathComponent("Downloads").path, L10n.tr("下载", "Downloads"))
        ]
        XCTAssertEqual(places.map(\.path), expected.map(\.0))
        XCTAssertEqual(places.map(\.name), expected.map(\.1))
    }
}
