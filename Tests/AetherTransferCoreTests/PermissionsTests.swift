import XCTest
@testable import AetherTransferCore

final class PermissionsTests: XCTestCase {
    func testPermissionsParsingAndOctalFormatting() {
        let p1 = POSIXPermissions(fromModeString: "-rwxr-xr-x")
        XCTAssertEqual(p1.octalString, "0755")
        XCTAssertEqual(p1.octalInt, 0o755)
        XCTAssertTrue(p1.owner.read && p1.owner.write && p1.owner.execute)
        XCTAssertTrue(p1.group.read && !p1.group.write && p1.group.execute)
        XCTAssertTrue(p1.others.read && !p1.others.write && p1.others.execute)

        let p2 = POSIXPermissions(fromModeString: "-rw-r--r--")
        XCTAssertEqual(p2.octalString, "0644")
        XCTAssertEqual(p2.octalInt, 0o644)
        XCTAssertTrue(p2.owner.read && p2.owner.write && !p2.owner.execute)
        XCTAssertTrue(p2.group.read && !p2.group.write && !p2.group.execute)
        XCTAssertTrue(p2.others.read && !p2.others.write && !p2.others.execute)
    }

    func testPermissionsFromOctal() {
        let p = POSIXPermissions(fromOctalString: "0700")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.modeString, "rwx------")
        XCTAssertEqual(p?.octalString, "0700")

        let invalid = POSIXPermissions(fromOctalString: "9999")
        XCTAssertNil(invalid)
    }

    func testPermissionsMutation() {
        var p = POSIXPermissions(fromOctalString: "0644")!
        p.owner.execute = true
        XCTAssertEqual(p.octalString, "0744")
        XCTAssertEqual(p.modeString, "rwxr--r--")
    }
}
