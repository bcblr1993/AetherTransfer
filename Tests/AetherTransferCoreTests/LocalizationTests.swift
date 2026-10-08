import Foundation
import XCTest
@testable import AetherTransferCore

final class LocalizationTests: XCTestCase {
    func testExplicitLanguageAndSystemFallback() {
        XCTAssertEqual(L10n.text("连接服务器", language: .english), "Connect to Server")
        XCTAssertEqual(L10n.text("连接服务器", language: .simplifiedChinese), "连接服务器")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["de-DE", "zh-TW", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
    }

    func testInterpolationPreservesUserNamesAndPercentSigns() {
        let name = "我的服务器 %@ #\nName"
        XCTAssertEqual(L10n.format("目标已存在：%@", arguments: [name], language: .english),
                       "Destination already exists: \(name)")
        XCTAssertEqual(L10n.format("已处理 %@ / %@ 个项目%@", arguments: ["1", "6", ""], language: .english),
                       "Processed 1 / 6")
        XCTAssertEqual(L10n.text(name, language: .english), name)
        XCTAssertEqual(L10n.text("等待中", language: .english), "Queued")
    }

    func testBothResourceTablesHaveMatchingKeysAndPlaceholders() throws {
        func table(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(language).lproj"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        }
        let english = try table("en"), chinese = try table("zh-Hans")
        XCTAssertGreaterThan(english.count, 400)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count, key)
            XCTAssertEqual(chinese[key], key)
        }
    }
}
