import Foundation
import Testing
@testable import AetherTransferCore

@Suite("Transmit v0.3.0 SyncOptions, EditorPreferences & TextFileHelper")
struct TransmitV3SyncPrefsTests {
    @Test func syncOptionsTimeOffsetAndTolerance() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let localRoot = URL(fileURLWithPath: "/local/root")
        let remoteRoot = "/remote/root"

        // Remote clock is 1 hour behind local (remoteDate + 3600 == localDate)
        let remoteMinus1h = baseDate.addingTimeInterval(-3600)
        let remoteWithinTolerance = baseDate.addingTimeInterval(-3600 + 1.5)
        let remoteOutsideTolerance = baseDate.addingTimeInterval(-3600 - 120)

        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "exact.txt", fileURL: localRoot.appendingPathComponent("exact.txt"), isDirectory: false, size: 100, modified: baseDate),
            LocalFileItem(relativePath: "tol.txt", fileURL: localRoot.appendingPathComponent("tol.txt"), isDirectory: false, size: 100, modified: baseDate),
            LocalFileItem(relativePath: "changed.txt", fileURL: localRoot.appendingPathComponent("changed.txt"), isDirectory: false, size: 100, modified: baseDate)
        ]

        let remoteFiles: [FileEntry] = [
            FileEntry(name: "exact.txt", path: "/remote/root/exact.txt", isDirectory: false, size: 100, modified: remoteMinus1h),
            FileEntry(name: "tol.txt", path: "/remote/root/tol.txt", isDirectory: false, size: 100, modified: remoteWithinTolerance),
            FileEntry(name: "changed.txt", path: "/remote/root/changed.txt", isDirectory: false, size: 100, modified: remoteOutsideTolerance)
        ]

        let withoutOffset = SyncEngine.generatePlan(
            localRoot: localRoot,
            localFiles: localFiles,
            remoteRoot: remoteRoot,
            remoteFiles: remoteFiles,
            direction: .localToRemote
        )
        #expect(withoutOffset.uploadItems.count == 3)

        let withOffset = SyncEngine.generatePlan(
            localRoot: localRoot,
            localFiles: localFiles,
            remoteRoot: remoteRoot,
            remoteFiles: remoteFiles,
            direction: .localToRemote,
            options: SyncOptions(timeOffsetSeconds: 3600)
        )
        #expect(withOffset.uploadItems.map(\.relativePath) == ["changed.txt"])
        #expect(withOffset.skipItems.count == 2)
        #expect(withOffset.deleteOrphans == false)
        #expect(withOffset.simulateOnly == false)

        // Bidirectional with time offset: changed.txt local is newer (diff = +120s) -> upload
        let biPlan = SyncEngine.generatePlan(
            localRoot: localRoot,
            localFiles: localFiles,
            remoteRoot: remoteRoot,
            remoteFiles: remoteFiles,
            direction: .bidirectional,
            options: SyncOptions(timeOffsetSeconds: 3600)
        )
        #expect(biPlan.uploadItems.map(\.relativePath) == ["changed.txt"])
        #expect(biPlan.downloadItems.isEmpty)
    }

    @Test func syncOptionsModifiedWithinWindowAndSimulateAndSymlinks() {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let recent = now.addingTimeInterval(-3600)        // 1 hour ago
        let stale = now.addingTimeInterval(-10 * 86_400)   // 10 days ago
        let localRoot = URL(fileURLWithPath: "/local/root")
        let remoteRoot = "/remote/root"

        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "recent.txt", fileURL: localRoot.appendingPathComponent("recent.txt"), isDirectory: false, size: 200, modified: recent),
            LocalFileItem(relativePath: "stale.txt", fileURL: localRoot.appendingPathComponent("stale.txt"), isDirectory: false, size: 300, modified: stale)
        ]
        let remoteFiles: [FileEntry] = [
            FileEntry(name: "remote_recent.txt", path: "/remote/root/remote_recent.txt", isDirectory: false, isSymbolicLink: false, size: 150, modified: recent),
            FileEntry(name: "remote_stale.txt", path: "/remote/root/remote_stale.txt", isDirectory: false, isSymbolicLink: false, size: 250, modified: stale),
            FileEntry(name: "symlink.txt", path: "/remote/root/symlink.txt", isDirectory: false, isSymbolicLink: true, size: 50, modified: recent)
        ]

        // 7-day window, followSymlinks = false, simulateOnly = true
        let plan = SyncEngine.generatePlan(
            localRoot: localRoot,
            localFiles: localFiles,
            remoteRoot: remoteRoot,
            remoteFiles: remoteFiles,
            direction: .bidirectional,
            options: SyncOptions(
                modifiedWithinSeconds: 7 * 86_400,
                followSymlinks: false,
                simulateOnly: true
            ),
            referenceDate: now
        )
        #expect(plan.simulateOnly == true)
        #expect(plan.deleteOrphans == false)
        #expect(plan.uploadItems.map(\.relativePath) == ["recent.txt"])
        #expect(plan.downloadItems.map(\.relativePath) == ["remote_recent.txt"])
        #expect(!plan.items.contains(where: { $0.relativePath == "symlink.txt" }))

        // With followSymlinks = true, symlink.txt is included
        let followPlan = SyncEngine.generatePlan(
            localRoot: localRoot,
            localFiles: localFiles,
            remoteRoot: remoteRoot,
            remoteFiles: remoteFiles,
            direction: .remoteToLocal,
            options: SyncOptions(
                modifiedWithinSeconds: 7 * 86_400,
                followSymlinks: true,
                simulateOnly: false
            ),
            referenceDate: now
        )
        #expect(followPlan.downloadItems.map(\.relativePath).sorted() == ["remote_recent.txt", "symlink.txt"])
    }

    @Test func estimateTimeOffsetMedianAndRounding() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let localRoot = URL(fileURLWithPath: "/local")
        let remoteRoot = "/srv/www"

        let localFiles: [LocalFileItem] = [
            LocalFileItem(relativePath: "a.txt", fileURL: localRoot.appendingPathComponent("a.txt"), isDirectory: false, size: 100, modified: baseDate),
            LocalFileItem(relativePath: "b.txt", fileURL: localRoot.appendingPathComponent("b.txt"), isDirectory: false, size: 200, modified: baseDate),
            LocalFileItem(relativePath: "c.txt", fileURL: localRoot.appendingPathComponent("c.txt"), isDirectory: false, size: 300, modified: baseDate),
            LocalFileItem(relativePath: "diffsize.txt", fileURL: localRoot.appendingPathComponent("diffsize.txt"), isDirectory: false, size: 400, modified: baseDate)
        ]
        let remoteFiles: [FileEntry] = [
            // +3604s, +3597s, and an outlier +18000s -> median is +3604s -> rounds to +3600s
            FileEntry(name: "a.txt", path: "/srv/www/a.txt", isDirectory: false, size: 100, modified: baseDate.addingTimeInterval(-3604)),
            FileEntry(name: "b.txt", path: "/srv/www/b.txt", isDirectory: false, size: 200, modified: baseDate.addingTimeInterval(-3597)),
            FileEntry(name: "c.txt", path: "/srv/www/c.txt", isDirectory: false, size: 300, modified: baseDate.addingTimeInterval(-18000)),
            // size differs -> ignored
            FileEntry(name: "diffsize.txt", path: "/srv/www/diffsize.txt", isDirectory: false, size: 999, modified: baseDate.addingTimeInterval(-7200))
        ]

        let estimated = SyncEngine.estimateTimeOffset(localFiles: localFiles, remoteFiles: remoteFiles, remoteRoot: remoteRoot)
        #expect(estimated == 3600)

        // Half-hour offset (+1802s -> 1800s)
        let halfHourLocals = [
            LocalFileItem(relativePath: "h.txt", fileURL: localRoot.appendingPathComponent("h.txt"), isDirectory: false, size: 100, modified: baseDate)
        ]
        let halfHourRemotes = [
            FileEntry(name: "h.txt", path: "/srv/www/h.txt", isDirectory: false, size: 100, modified: baseDate.addingTimeInterval(-1802))
        ]
        #expect(SyncEngine.estimateTimeOffset(localFiles: halfHourLocals, remoteFiles: halfHourRemotes, remoteRoot: remoteRoot) == 1800)

        // Identical mtimes -> 0
        let identicalRemotes = [
            FileEntry(name: "h.txt", path: "/srv/www/h.txt", isDirectory: false, size: 100, modified: baseDate)
        ]
        #expect(SyncEngine.estimateTimeOffset(localFiles: halfHourLocals, remoteFiles: identicalRemotes, remoteRoot: remoteRoot) == 0)
    }

    @Test func syncPlanExportReportCSVRFC4180() {
        let srcDate = Date(timeIntervalSince1970: 1_700_000_000)
        let dstDate = Date(timeIntervalSince1970: 1_700_000_500)
        let items = [
            SyncItem(
                relativePath: "docs/a, \"quoted\".txt",
                actionType: .upload,
                size: 1024,
                sourceDate: srcDate,
                targetDate: dstDate,
                isEnabled: true
            ),
            SyncItem(
                relativePath: "unchanged.txt",
                actionType: .skipIdentical,
                size: 512,
                sourceDate: srcDate,
                targetDate: srcDate,
                isEnabled: false
            )
        ]
        let plan = SyncPlan(direction: .localToRemote, simulateOnly: true, items: items)
        let csv = plan.exportReportCSV()
        let lines = csv.components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines[0] == "RelativePath,Action,SizeBytes,SourceDate,TargetDate,Enabled")
        #expect(lines[1].hasPrefix("\"docs/a, \"\"quoted\"\".txt\","))
        #expect(lines[1].hasSuffix(",true"))
        #expect(lines[2].hasPrefix("unchanged.txt,"))
        #expect(lines[2].hasSuffix(",false"))
    }

    @MainActor
    @Test func filesPreferencesStorePersistenceAndPreferredEditorResolution() {
        let suiteName = "com.aethernative.AetherTransfer.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = FilesPreferencesStore(userDefaults: defaults)
        #expect(store.doubleClickAction == .transfer)
        #expect(store.defaultExternalEditorPath == "")
        #expect(store.customEditors.isEmpty)
        #expect(store.askBeforeDeleting == true)
        #expect(store.transferMode == .automatic)
        #expect(store.notifyOnTransferComplete == true)
        #expect(store.playSoundOnTransferComplete == false)
        #expect(store.preferredEditorURL(for: "main.swift") == nil)

        store.doubleClickAction = .editExternal
        store.defaultExternalEditorPath = "/Applications/TextEdit.app"
        store.upsertCustomEditor(fileExtension: ".Swift", appPath: "/Applications/Xcode.app", appName: "Xcode")
        store.upsertCustomEditor(fileExtension: "md", appPath: "/Applications/Zed.app", appName: "Zed")
        store.askBeforeDeleting = false
        store.transferMode = .binary
        store.notifyOnTransferComplete = false
        store.playSoundOnTransferComplete = true

        // Verify case-insensitive extension matching and default fallback
        #expect(store.preferredEditorURL(for: "AppDelegate.SWIFT")?.path == "/Applications/Xcode.app")
        #expect(store.preferredEditorURL(for: "README.MD")?.path == "/Applications/Zed.app")
        #expect(store.preferredEditorURL(for: "archive.bin")?.path == "/Applications/TextEdit.app")

        // Verify persistence across new instance backed by the same UserDefaults
        let reloaded = FilesPreferencesStore(userDefaults: defaults)
        #expect(reloaded.doubleClickAction == .editExternal)
        #expect(reloaded.defaultExternalEditorPath == "/Applications/TextEdit.app")
        #expect(reloaded.customEditors.count == 2)
        #expect(reloaded.askBeforeDeleting == false)
        #expect(reloaded.transferMode == .binary)
        #expect(reloaded.notifyOnTransferComplete == false)
        #expect(reloaded.playSoundOnTransferComplete == true)
        #expect(reloaded.preferredEditorURL(for: "file.swift")?.path == "/Applications/Xcode.app")
    }

    @Test func textFileHelperEncodeDecodeAndLineCounts() throws {
        let chinese = "你好，AetherTransfer 2026！"
        for enc in [TextFileEncoding.utf8, .utf16, .gb18030] {
            let encoded = try TextFileHelper.encodeText(chinese, encoding: enc)
            let decoded = try TextFileHelper.decodeText(encoded, encoding: enc)
            #expect(decoded == chinese)
        }

        let latin = "café résumé naïve"
        let latinData = try TextFileHelper.encodeText(latin, encoding: .isoLatin1)
        #expect(try TextFileHelper.decodeText(latinData, encoding: .isoLatin1) == latin)

        // Empty data decodes to empty string
        #expect(try TextFileHelper.decodeText(Data(), encoding: .utf8) == "")
        #expect(try TextFileHelper.decodeText(Data(), encoding: .utf16) == "")

        // Unrepresentable text throws encodingFailed
        #expect(throws: TextFileEncodingError.encodingFailed(.isoLatin1)) {
            _ = try TextFileHelper.encodeText(chinese, encoding: .isoLatin1)
        }

        // Invalid UTF-8 throws decodingFailed
        #expect(throws: TextFileEncodingError.decodingFailed(.utf8)) {
            _ = try TextFileHelper.decodeText(Data([0xFF, 0xFE, 0x80, 0x81]), encoding: .utf8)
        }

        // Line and character counts
        let emptyCounts = TextFileHelper.lineAndColumnCounts("")
        #expect(emptyCounts.lines == 0 && emptyCounts.characters == 0)

        let singleCounts = TextFileHelper.lineAndColumnCounts("hello")
        #expect(singleCounts.lines == 1 && singleCounts.characters == 5)

        let multiCounts = TextFileHelper.lineAndColumnCounts("a\nb\nc")
        #expect(multiCounts.lines == 3 && multiCounts.characters == 5)

        let crlfCounts = TextFileHelper.lineAndColumnCounts("ab\r\ncd\r\n")
        #expect(crlfCounts.lines == 2 && crlfCounts.characters == 6)
    }
}
