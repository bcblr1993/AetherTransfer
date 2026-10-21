import XCTest
@testable import AetherTransferCore

final class AutoUpdaterTests: XCTestCase {

    func testSemanticVersionParsingAndComparison() {
        let v010 = SemanticVersion(parsing: "0.1.0")
        let v011 = SemanticVersion(parsing: "v0.1.1")
        let v020Beta = SemanticVersion(parsing: "0.2.0-beta.1")
        let v020 = SemanticVersion(parsing: "0.2.0")
        let v10 = SemanticVersion(parsing: "1.0")

        XCTAssertNotNil(v010)
        XCTAssertNotNil(v011)
        XCTAssertNotNil(v020Beta)
        XCTAssertNotNil(v020)
        XCTAssertEqual(v10, SemanticVersion(major: 1, minor: 0, patch: 0))

        XCTAssertTrue(v010! < v011!)
        XCTAssertTrue(v011! < v020Beta!)
        XCTAssertTrue(v020Beta! < v020!)
        XCTAssertTrue(v020! < v10!)
        XCTAssertNil(SemanticVersion(parsing: "invalid.version"))
    }

    func testManifestValidationAndEvaluation() throws {
        let validSHA = String(repeating: "a1", count: 32)
        let release = UpdateRelease(
            version: "0.1.1",
            buildNumber: "2026102201",
            publishedAt: "2026-10-22T00:00:00Z",
            downloadURL: "https://www.aethernative.com/downloads/AetherTransfer-0.1.1-arm64.zip",
            sha256: validSHA,
            sizeBytes: 2_048_000,
            minimumSystemVersion: "26.0",
            releaseNotesZh: "修复问题并提升传输稳定性。",
            releaseNotesEn: "Bug fixes and stability improvements."
        )
        let manifest = UpdateManifest(latest: release)
        let data = try JSONEncoder().encode(manifest)

        let parsed = try AutoUpdater.parseManifest(from: data)
        XCTAssertEqual(parsed.latest.version, "0.1.1")

        let available = try AutoUpdater.evaluateUpdate(currentVersion: "0.1.0", manifest: parsed)
        XCTAssertNotNil(available)
        XCTAssertEqual(available?.version, "0.1.1")

        let upToDate = try AutoUpdater.evaluateUpdate(currentVersion: "0.1.1", manifest: parsed)
        XCTAssertNil(upToDate)

        // Reject HTTP download URL
        let insecureRelease = UpdateRelease(
            version: "0.1.2",
            publishedAt: "2026-10-22T00:00:00Z",
            downloadURL: "http://example.com/update.zip",
            sha256: validSHA,
            sizeBytes: 1024,
            releaseNotesZh: "测试",
            releaseNotesEn: "Test"
        )
        XCTAssertThrowsError(try insecureRelease.validate(allowLocalFileURL: false)) { error in
            XCTAssertEqual(error as? AutoUpdateError, .insecureDownloadURL)
        }
    }

    func testDownloadVerifyAndAtomicBundleReplacement() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("AetherUpdaterTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. Build a mock signed v0.1.1 .app bundle
        let sourceBundleDir = tempRoot.appendingPathComponent("build/AetherTransfer.app", isDirectory: true)
        let macOSDir = sourceBundleDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        let execURL = macOSDir.appendingPathComponent("AetherTransfer")
        let scriptExec = "#!/bin/sh\necho 'AetherTransfer 0.1.1'\n"
        try scriptExec.data(using: .utf8)!.write(to: execURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "AetherTransfer",
            "CFBundleIdentifier": "com.aethernative.AetherTransfer",
            "CFBundleName": "AetherTransfer",
            "CFBundleShortVersionString": "0.1.1",
            "CFBundleVersion": "2026102201",
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: sourceBundleDir.appendingPathComponent("Contents/Info.plist"))

        // Ad-hoc sign the mock bundle so `codesign --verify --deep --strict` succeeds
        let signProc = Process()
        signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProc.arguments = ["--force", "--sign", "-", sourceBundleDir.path]
        try signProc.run()
        signProc.waitUntilExit()
        XCTAssertEqual(signProc.terminationStatus, 0)

        // 2. Zip the .app bundle using ditto
        let zipURL = tempRoot.appendingPathComponent("AetherTransfer-0.1.1.zip")
        try ArchiveHelper.createZip(from: [sourceBundleDir], destinationZipURL: zipURL)
        let sha256 = try AutoUpdater.computeSHA256Hex(of: zipURL)
        let zipSize = (try fm.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        let release = UpdateRelease(
            version: "0.1.1",
            buildNumber: "2026102201",
            publishedAt: "2026-10-22T00:00:00Z",
            downloadURL: zipURL.absoluteString,
            sha256: sha256,
            sizeBytes: zipSize,
            releaseNotesZh: "支持应用内在线更新并立即重启。",
            releaseNotesEn: "Added in-app update with immediate restart."
        )

        // 3. Test tampered SHA-256 rejection first
        let badRelease = UpdateRelease(
            version: "0.1.1",
            publishedAt: "2026-10-22T00:00:00Z",
            downloadURL: zipURL.absoluteString,
            sha256: String(repeating: "00", count: 32),
            sizeBytes: zipSize,
            releaseNotesZh: "",
            releaseNotesEn: ""
        )
        do {
            _ = try await AutoUpdater.downloadAndStageUpdate(
                release: badRelease,
                stagingRoot: tempRoot.appendingPathComponent("staging-bad"),
                allowLocalFileURL: true,
                requireCodeSignature: true
            )
            XCTFail("Expected checksumMismatch error")
        } catch let error as AutoUpdateError {
            if case .checksumMismatch = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // 4. Stage valid update and verify signature + Info.plist
        let stagedApp = try await AutoUpdater.downloadAndStageUpdate(
            release: release,
            stagingRoot: tempRoot.appendingPathComponent("staging-good"),
            allowLocalFileURL: true,
            requireCodeSignature: true
        )
        XCTAssertTrue(fm.fileExists(atPath: stagedApp.path))

        // 5. Create an existing "old" target .app and run the generated replacement script
        let targetApp = tempRoot.appendingPathComponent("Applications/AetherTransfer.app", isDirectory: true)
        try fm.createDirectory(at: targetApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old-0.1.0".data(using: .utf8)!.write(to: targetApp.appendingPathComponent("Contents/old.txt"))

        // Use a non-existent PID (999999) so the script doesn't wait, and relaunch: false for unit test
        let script = AutoUpdater.generateRelaunchScript(
            stagedAppURL: stagedApp,
            targetAppURL: targetApp,
            processIdentifier: 999999,
            relaunch: false
        )
        let scriptFile = tempRoot.appendingPathComponent("run-swap.sh")
        try script.data(using: .utf8)!.write(to: scriptFile)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)

        let swapProc = Process()
        swapProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        swapProc.arguments = [scriptFile.path]
        try swapProc.run()
        swapProc.waitUntilExit()
        XCTAssertEqual(swapProc.terminationStatus, 0)

        // Verify targetApp now has the new 0.1.1 Info.plist and old.txt is gone
        XCTAssertFalse(fm.fileExists(atPath: targetApp.appendingPathComponent("Contents/old.txt").path))
        let installedPlistData = try Data(contentsOf: targetApp.appendingPathComponent("Contents/Info.plist"))
        let installedPlist = try PropertyListSerialization.propertyList(from: installedPlistData, format: nil) as? [String: Any]
        XCTAssertEqual(installedPlist?["CFBundleShortVersionString"] as? String, "0.1.1")
    }

    func testShellAndAppleScriptEscaping() {
        let trickyPath = "/Users/test/My 'Secret' Folder/\"quote\"/file"
        let singleEscaped = ShellEscape.singleQuoted(trickyPath)
        XCTAssertEqual(singleEscaped, "'/Users/test/My '\\''Secret'\\'' Folder/\"quote\"/file'")

        let asEscaped = ShellEscape.appleScriptQuoted("cd '/Users/test/My '\\''Secret'\\'' Folder'")
        XCTAssertEqual(asEscaped, "\"cd '/Users/test/My '\\\\''Secret'\\\\'' Folder'\"")
    }

    func testGitHubReleaseManifestFallbackParsing() throws {
        let validSHA = String(repeating: "b2", count: 32)
        let githubJSON = """
        {
          "tag_name": "v0.1.2",
          "published_at": "2026-10-23T10:00:00Z",
          "body": "Release notes for v0.1.2\\nSHA256: \(validSHA)",
          "assets": [
            {
              "name": "AetherTransfer-0.1.2-arm64.zip",
              "browser_download_url": "https://github.com/bcblr1993/AetherTransfer/releases/download/v0.1.2/AetherTransfer-0.1.2-arm64.zip",
              "size": 1572864,
              "digest": "sha256:\(validSHA)"
            }
          ]
        }
        """.data(using: .utf8)!

        let manifest = try AutoUpdater.parseManifest(from: githubJSON)
        XCTAssertEqual(manifest.latest.version, "0.1.2")
        XCTAssertEqual(manifest.latest.sha256, validSHA)
        XCTAssertEqual(manifest.latest.sizeBytes, 1_572_864)
    }
}
