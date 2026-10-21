import XCTest
@testable import AetherTransferCore

final class SyncTests: XCTestCase {
    func testSyncPlanLocalToRemoteUploadsMissingAndModified() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let newerDate = Date(timeIntervalSince1970: 1700001000)

        let localURL = URL(fileURLWithPath: "/local/root")
        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "docs/readme.txt", fileURL: localURL.appendingPathComponent("docs/readme.txt"), isDirectory: false, size: 100, modified: baseDate),
            LocalFileItem(relativePath: "images/logo.png", fileURL: localURL.appendingPathComponent("images/logo.png"), isDirectory: false, size: 500, modified: newerDate),
            LocalFileItem(relativePath: "images/banner.png", fileURL: localURL.appendingPathComponent("images/banner.png"), isDirectory: false, size: 800, modified: baseDate)
        ]

        let remoteRoot = "/remote/root"
        let remoteFiles: [FileEntry] = [
            // readme.txt is identical in size and date
            FileEntry(name: "readme.txt", path: "/remote/root/docs/readme.txt", isDirectory: false, isSymbolicLink: false, size: 100, modified: baseDate),
            // logo.png on remote is older and smaller
            FileEntry(name: "logo.png", path: "/remote/root/images/logo.png", isDirectory: false, isSymbolicLink: false, size: 400, modified: baseDate),
            // extra remote file
            FileEntry(name: "old.log", path: "/remote/root/old.log", isDirectory: false, isSymbolicLink: false, size: 200, modified: baseDate)
        ]

        // Default deleteOrphans is false
        let plan = SyncEngine.generatePlan(
            localRoot: localURL,
            localFiles: localFiles,
            remoteRoot: remoteRoot,
            remoteFiles: remoteFiles,
            direction: .localToRemote,
            deleteOrphans: false
        )

        // banner.png is missing on remote -> upload
        // logo.png is newer and different size -> upload
        // readme.txt is identical -> skip
        // old.log is orphan on remote, but deleteOrphans is false -> skipped / no action

        XCTAssertEqual(plan.uploadItems.count, 2)
        XCTAssertTrue(plan.uploadItems.contains(where: { $0.relativePath == "images/banner.png" }))
        XCTAssertTrue(plan.uploadItems.contains(where: { $0.relativePath == "images/logo.png" }))
        XCTAssertEqual(plan.downloadItems.count, 0)
        XCTAssertEqual(plan.deleteItems.count, 0)
        XCTAssertEqual(plan.totalTransferBytes, 500 + 800)
    }

    func testSyncPlanSafetyDoesNotDeleteRemoteByDefault() {
        let baseDate = Date()
        let localURL = URL(fileURLWithPath: "/local/root")
        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "keep.txt", fileURL: localURL.appendingPathComponent("keep.txt"), isDirectory: false, size: 100, modified: baseDate)
        ]
        let remoteFiles: [FileEntry] = [
            FileEntry(name: "keep.txt", path: "/remote/root/keep.txt", isDirectory: false, isSymbolicLink: false, size: 100, modified: baseDate),
            FileEntry(name: "orphan.txt", path: "/remote/root/orphan.txt", isDirectory: false, isSymbolicLink: false, size: 200, modified: baseDate)
        ]

        // 1. deleteOrphans = false (default)
        let safePlan = SyncEngine.generatePlan(
            localRoot: localURL,
            localFiles: localFiles,
            remoteRoot: "/remote/root",
            remoteFiles: remoteFiles,
            direction: .localToRemote,
            deleteOrphans: false
        )
        XCTAssertEqual(safePlan.deleteItems.count, 0, "Default must NEVER delete remote orphans")

        // 2. deleteOrphans = true explicitly
        let deletePlan = SyncEngine.generatePlan(
            localRoot: localURL,
            localFiles: localFiles,
            remoteRoot: "/remote/root",
            remoteFiles: remoteFiles,
            direction: .localToRemote,
            deleteOrphans: true
        )
        XCTAssertEqual(deletePlan.deleteItems.count, 1)
        XCTAssertEqual(deletePlan.deleteItems.first?.relativePath, "orphan.txt")
    }

    func testSyncPlanRemoteToLocalDownloadsMissingAndModified() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let newerDate = Date(timeIntervalSince1970: 1700001000)

        let localURL = URL(fileURLWithPath: "/local/root")
        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "app.cfg", fileURL: localURL.appendingPathComponent("app.cfg"), isDirectory: false, size: 50, modified: baseDate)
        ]

        let remoteFiles: [FileEntry] = [
            // app.cfg is newer on remote
            FileEntry(name: "app.cfg", path: "/remote/root/app.cfg", isDirectory: false, isSymbolicLink: false, size: 60, modified: newerDate),
            // asset.bin is missing locally
            FileEntry(name: "asset.bin", path: "/remote/root/asset.bin", isDirectory: false, isSymbolicLink: false, size: 1024, modified: baseDate)
        ]

        let plan = SyncEngine.generatePlan(
            localRoot: localURL,
            localFiles: localFiles,
            remoteRoot: "/remote/root",
            remoteFiles: remoteFiles,
            direction: .remoteToLocal,
            deleteOrphans: false
        )

        XCTAssertEqual(plan.downloadItems.count, 2)
        XCTAssertTrue(plan.downloadItems.contains(where: { $0.relativePath == "app.cfg" }))
        XCTAssertTrue(plan.downloadItems.contains(where: { $0.relativePath == "asset.bin" }))
        XCTAssertEqual(plan.uploadItems.count, 0)
        XCTAssertEqual(plan.totalTransferBytes, 60 + 1024)
    }

    func testSyncPlanBidirectionalSync() {
        let oldDate = Date(timeIntervalSince1970: 1700000000)
        let newDate = Date(timeIntervalSince1970: 1700002000)

        let localURL = URL(fileURLWithPath: "/local/root")
        let localFiles: [LocalFileItem] = [
            // local-only file -> upload
            LocalFileItem(relativePath: "local_only.txt", fileURL: localURL.appendingPathComponent("local_only.txt"), isDirectory: false, size: 100, modified: newDate),
            // local is newer -> upload
            LocalFileItem(relativePath: "shared.txt", fileURL: localURL.appendingPathComponent("shared.txt"), isDirectory: false, size: 120, modified: newDate),
            // local is older -> remote wins -> download
            LocalFileItem(relativePath: "doc.pdf", fileURL: localURL.appendingPathComponent("doc.pdf"), isDirectory: false, size: 500, modified: oldDate)
        ]

        let remoteFiles: [FileEntry] = [
            // remote-only file -> download
            FileEntry(name: "remote_only.txt", path: "/remote/root/remote_only.txt", isDirectory: false, isSymbolicLink: false, size: 200, modified: newDate),
            // remote is older
            FileEntry(name: "shared.txt", path: "/remote/root/shared.txt", isDirectory: false, isSymbolicLink: false, size: 110, modified: oldDate),
            // remote is newer
            FileEntry(name: "doc.pdf", path: "/remote/root/doc.pdf", isDirectory: false, isSymbolicLink: false, size: 550, modified: newDate)
        ]

        let plan = SyncEngine.generatePlan(
            localRoot: localURL,
            localFiles: localFiles,
            remoteRoot: "/remote/root",
            remoteFiles: remoteFiles,
            direction: .bidirectional,
            deleteOrphans: false
        )

        XCTAssertEqual(plan.uploadItems.count, 2) // local_only.txt, shared.txt
        XCTAssertEqual(plan.downloadItems.count, 2) // remote_only.txt, doc.pdf
        XCTAssertTrue(plan.uploadItems.contains(where: { $0.relativePath == "local_only.txt" }))
        XCTAssertTrue(plan.uploadItems.contains(where: { $0.relativePath == "shared.txt" }))
        XCTAssertTrue(plan.downloadItems.contains(where: { $0.relativePath == "remote_only.txt" }))
        XCTAssertTrue(plan.downloadItems.contains(where: { $0.relativePath == "doc.pdf" }))
    }

    func testSyncItemToggleAndTransferByteCalculation() {
        let baseDate = Date()
        let localURL = URL(fileURLWithPath: "/local/root")
        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "file1.txt", fileURL: localURL.appendingPathComponent("file1.txt"), isDirectory: false, size: 1000, modified: baseDate),
            LocalFileItem(relativePath: "file2.txt", fileURL: localURL.appendingPathComponent("file2.txt"), isDirectory: false, size: 2000, modified: baseDate)
        ]

        var plan = SyncEngine.generatePlan(
            localRoot: localURL,
            localFiles: localFiles,
            remoteRoot: "/remote/root",
            remoteFiles: [],
            direction: .localToRemote,
            deleteOrphans: false
        )

        XCTAssertEqual(plan.activeItems.count, 2)
        XCTAssertEqual(plan.totalTransferBytes, 3000)

        // Toggle file1 off
        if let idx = plan.items.firstIndex(where: { $0.relativePath == "file1.txt" }) {
            plan.items[idx].isEnabled = false
        }

        XCTAssertEqual(plan.activeItems.count, 1)
        XCTAssertEqual(plan.totalTransferBytes, 2000)
    }
}
