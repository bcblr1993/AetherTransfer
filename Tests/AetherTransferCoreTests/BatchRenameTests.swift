import XCTest
@testable import AetherTransferCore

final class BatchRenameTests: XCTestCase {
    func testReplaceTextRule() {
        let files = ["IMG_001.jpg", "IMG_002.png", "other.txt"]
        let renamer = BatchRenamer(rule: .replace(find: "IMG_", replaceWith: "Photo_"))
        let plan = renamer.plan(for: files)

        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[0].newName, "Photo_001.jpg")
        XCTAssertEqual(plan[1].newName, "Photo_002.png")
        XCTAssertEqual(plan[2].newName, "other.txt")
        XCTAssertFalse(plan[0].hasError)
    }

    func testPrefixAndSuffixRules() {
        let files = ["report.pdf", "data.csv"]
        let prefixRenamer = BatchRenamer(rule: .addPrefix("v1_"))
        let plan1 = prefixRenamer.plan(for: files)
        XCTAssertEqual(plan1.map(\.newName), ["v1_report.pdf", "v1_data.csv"])

        let suffixRenamer = BatchRenamer(rule: .addSuffix("_final"))
        let plan2 = suffixRenamer.plan(for: files)
        XCTAssertEqual(plan2.map(\.newName), ["report_final.pdf", "data_final.csv"])
    }

    func testSequenceNumberingRule() {
        let files = ["a.jpg", "b.jpg", "c.jpg"]
        let renamer = BatchRenamer(rule: .sequence(format: "Pic_{N}", start: 1, padding: 3))
        let plan = renamer.plan(for: files)

        XCTAssertEqual(plan.map(\.newName), ["Pic_001.jpg", "Pic_002.jpg", "Pic_003.jpg"])
    }

    func testCollisionDetection() {
        let files = ["a.txt", "b.txt"]
        // Renaming everything to the same base causes collision
        let renamer = BatchRenamer(rule: .replace(find: "b", replaceWith: "a"))
        let plan = renamer.plan(for: files)

        XCTAssertEqual(plan[1].newName, "a.txt")
        XCTAssertTrue(plan[1].hasError)
        XCTAssertEqual(plan[1].errorDescription, "名称冲突")
    }
}
