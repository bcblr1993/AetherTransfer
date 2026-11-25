import Foundation
import Testing
@testable import AetherTransferCore

@Test func fileRulesStoreFilterLocalItemsExcludesSkippedDirectoriesAndMatches() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aether-wave3-rules-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let gitDir = tempDir.appendingPathComponent(".git/objects", isDirectory: true)
    let nodeModulesDir = tempDir.appendingPathComponent("frontend/node_modules/left-pad", isDirectory: true)
    let srcDir = tempDir.appendingPathComponent("frontend/src", isDirectory: true)
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModulesDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

    try Data("ref".utf8).write(to: tempDir.appendingPathComponent(".git/HEAD"))
    try Data("obj".utf8).write(to: gitDir.appendingPathComponent("ab"))
    try Data("pad".utf8).write(to: nodeModulesDir.appendingPathComponent("index.js"))
    try Data("ds".utf8).write(to: tempDir.appendingPathComponent(".DS_Store"))
    try Data("rf".utf8).write(to: srcDir.appendingPathComponent("._App.swift"))
    try Data("swp".utf8).write(to: srcDir.appendingPathComponent("App.swift.swp"))
    try Data("app".utf8).write(to: srcDir.appendingPathComponent("App.swift"))

    let walked = try LocalFiles.walk(tempDir, showHidden: true)
    let filtered = FileRulesStore.filterLocalItems(walked, rules: FileRulesStore.defaultRules, scope: .transfersAndSync)
    let remainingPaths = Set(filtered.map(\.relativePath))

    #expect(remainingPaths.contains("frontend"))
    #expect(remainingPaths.contains("frontend/src"))
    #expect(remainingPaths.contains("frontend/src/App.swift"))
    #expect(!remainingPaths.contains(".git"))
    #expect(!remainingPaths.contains(".git/HEAD"))
    #expect(!remainingPaths.contains(".git/objects/ab"))
    #expect(!remainingPaths.contains("frontend/node_modules"))
    #expect(!remainingPaths.contains("frontend/node_modules/left-pad/index.js"))
    #expect(!remainingPaths.contains(".DS_Store"))
    #expect(!remainingPaths.contains("frontend/src/._App.swift"))
    #expect(!remainingPaths.contains("frontend/src/App.swift.swp"))

    // Disabling all rules restores the full tree
    let disabledRules = FileRulesStore.defaultRules.map { rule in
        var copy = rule
        copy.isEnabled = false
        return copy
    }
    let unfiltered = FileRulesStore.filterLocalItems(walked, rules: disabledRules, scope: .transfersAndSync)
    #expect(unfiltered.count == walked.count)
}

@Test func fileClipboardSiteWebURLAndPreferredUploadURLMapping() {
    let scopedProfile = ServerProfile(
        name: "CDN Web",
        host: "origin.example.com",
        port: 22,
        username: "deploy",
        protocolKind: .sftp,
        initialPath: "/var/www/site",
        siteURL: "https://cdn.example.com/assets/"
    )

    #expect(
        FileClipboard.siteWebURL(for: "/var/www/site/images/hero banner.png", isDirectory: false, profile: scopedProfile)?.absoluteString
            == "https://cdn.example.com/assets/images/hero%20banner.png"
    )
    #expect(
        FileClipboard.preferredUploadURLString(forRemotePath: "/var/www/site/app.js", isDirectory: false, profile: scopedProfile)
            == "https://cdn.example.com/assets/app.js"
    )

    let s3Profile = ServerProfile(
        name: "R2 Bucket",
        host: "r2.example.com",
        port: 443,
        username: "AKIAEXAMPLE",
        protocolKind: .s3,
        initialPath: "/",
        s3Bucket: "media",
        s3Region: "auto",
        s3PathStyle: true,
        siteURL: ""
    )
    #expect(
        FileClipboard.preferredUploadURLString(forRemotePath: "/releases/v0.2.0.zip", isDirectory: false, profile: s3Profile)
            == "https://r2.example.com/media/releases/v0.2.0.zip"
    )

    let sftpNoSiteProfile = ServerProfile(
        name: "Bare Host",
        host: "files.example.com",
        port: 2222,
        username: "alice",
        protocolKind: .sftp,
        initialPath: "/srv",
        siteURL: ""
    )
    #expect(
        FileClipboard.preferredUploadURLString(forRemotePath: "/srv/report.pdf", isDirectory: false, profile: sftpNoSiteProfile)
            == "sftp://files.example.com:2222/srv/report.pdf"
    )
}

@Test func dropletRoundTripAndSavedProfileURLResolution() throws {
    let profileId = UUID()
    let profile = ServerProfile(
        id: profileId,
        name: "Staging",
        host: "staging.example.com",
        port: 22,
        username: "deployer",
        protocolKind: .sftp,
        initialPath: "/var/www/staging",
        defaultLocalPath: "/tmp"
    )

    let uploadURL = try #require(
        AetherURLCommand.buildUploadURL(
            profileId: profileId,
            remotePath: "/var/www/staging/builds",
            localURLs: [URL(fileURLWithPath: "/tmp/app.zip")]
        )
    )
    let uploadCommand = try AetherURLCommand.parse(uploadURL, savedProfiles: [profile])
    #expect(uploadCommand == .upload(
        profileId: profileId,
        remotePath: "/var/www/staging/builds",
        localURLs: [URL(fileURLWithPath: "/tmp/app.zip")]
    ))

    let connectSavedURL = URL(string: "aethertransfer://connect?profileId=\(profileId.uuidString)")!
    let connectCommand = try AetherURLCommand.parse(connectSavedURL, savedProfiles: [profile])
    #expect(connectCommand == .connect(profile))

    let ftpsURL = URL(string: "ftps://user:DoNotPersistPassword!@ftps.example.com:990/drop/dir")!
    let ftpsCommand = try AetherURLCommand.parse(ftpsURL, savedProfiles: [profile])
    guard case .connect(let ftpsProfile) = ftpsCommand else {
        Issue.record("Expected .connect for ftps URL")
        return
    }
    #expect(ftpsProfile.protocolKind == .ftps)
    #expect(ftpsProfile.host == "ftps.example.com")
    #expect(ftpsProfile.port == 990)
    #expect(ftpsProfile.username == "user")
    #expect(ftpsProfile.initialPath == "/drop/dir")
}
