import Foundation
import os
import Testing
@testable import AetherTransferCore

@Test func skipRulePredicatesMatchModesSizesDatesAndDefaults() throws {
    // 1. Case-insensitive name, extension, and glob matching
    let logRule = SkipRule(
        name: "Logs and Temp",
        matchMode: .any,
        scope: .all,
        predicates: [
            RulePredicate(field: .fileExtension, op: .is, value: ".LOG"),
            RulePredicate(field: .name, op: .matchesGlob, value: "*.SWP")
        ]
    )
    #expect(logRule.matches(name: "App.log", relativePath: "logs/App.log", isDirectory: false, size: 10, modified: nil))
    #expect(logRule.matches(name: ".main.swift.swp", relativePath: "src/.main.swift.swp", isDirectory: false, size: 10, modified: nil))
    #expect(!logRule.matches(name: "logs", relativePath: "logs", isDirectory: true, size: 0, modified: nil))
    #expect(!logRule.matches(name: "main.swift", relativePath: "src/main.swift", isDirectory: false, size: 10, modified: nil))

    // 2. `.all` and `.none` modes with size & path predicates
    let bigBuildArtifact = SkipRule(
        name: "Large Build Artifacts",
        matchMode: .all,
        scope: .transfersAndSync,
        predicates: [
            RulePredicate(field: .path, op: .beginsWith, value: "BUILD/"),
            RulePredicate(field: .sizeBytes, op: .greaterThan, value: "10 KB")
        ]
    )
    #expect(bigBuildArtifact.matches(name: "app.bin", relativePath: "build/app.bin", isDirectory: false, size: 20 * 1024, modified: nil))
    #expect(!bigBuildArtifact.matches(name: "small.bin", relativePath: "build/small.bin", isDirectory: false, size: 512, modified: nil))
    #expect(!bigBuildArtifact.matches(name: "build", relativePath: "build", isDirectory: true, size: 0, modified: nil))

    let allowOnlyAssets = SkipRule(
        name: "Skip Non-Media",
        matchMode: .none,
        scope: .all,
        predicates: [
            RulePredicate(field: .fileExtension, op: .is, value: "png"),
            RulePredicate(field: .fileExtension, op: .is, value: "jpg")
        ]
    )
    #expect(!allowOnlyAssets.matches(name: "hero.PNG", relativePath: "hero.PNG", isDirectory: false, size: 100, modified: nil))
    #expect(allowOnlyAssets.matches(name: "notes.txt", relativePath: "notes.txt", isDirectory: false, size: 100, modified: nil))

    // 3. Date & relative age comparisons
    let refDate = Date(timeIntervalSince1970: 1_760_000_000)
    let tenDaysAgo = refDate.addingTimeInterval(-10 * 86_400)
    let twoDaysAgo = refDate.addingTimeInterval(-2 * 86_400)
    let oldFilesRule = SkipRule(
        name: "Older than 7 days",
        matchMode: .all,
        scope: .all,
        predicates: [RulePredicate(field: .modifiedDate, op: .lessThan, value: "7d")]
    )
    #expect(oldFilesRule.matches(name: "old.tar", relativePath: "old.tar", isDirectory: false, size: 10, modified: tenDaysAgo, referenceDate: refDate))
    #expect(!oldFilesRule.matches(name: "fresh.tar", relativePath: "fresh.tar", isDirectory: false, size: 10, modified: twoDaysAgo, referenceDate: refDate))

    let isoRule = SkipRule(
        name: "Newer than cutoff",
        matchMode: .all,
        scope: .all,
        predicates: [RulePredicate(field: .modifiedDate, op: .greaterThan, value: "2025-01-01T00:00:00Z")]
    )
    #expect(isoRule.matches(name: "new.txt", relativePath: "new.txt", isDirectory: false, size: 10, modified: Date(timeIntervalSince1970: 1_750_000_000)))
    #expect(!isoRule.matches(name: "old.txt", relativePath: "old.txt", isDirectory: false, size: 10, modified: Date(timeIntervalSince1970: 1_700_000_000)))

    // 4. FileRulesStore defaults, ASCII extensions, and UserDefaults persistence
    let suiteName = "com.aethernative.AetherTransfer.tests.rules.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let store = FileRulesStore(suiteName: suiteName)

    let defaults = store.loadRules()
    #expect(defaults.count == 6)
    #expect(store.shouldSkip(name: ".DS_Store", relativePath: "sub/.DS_Store"))
    #expect(store.shouldSkip(name: "HEAD", relativePath: ".git/HEAD"))
    #expect(store.shouldSkip(name: "index.js", relativePath: "web/node_modules/pkg/index.js"))
    #expect(store.shouldSkip(name: "entries", relativePath: ".svn/entries"))
    #expect(store.shouldSkip(name: ".README.swp", relativePath: "docs/.README.swp"))
    #expect(store.shouldSkip(name: "._photo.jpg", relativePath: "img/._photo.jpg"))
    #expect(!store.shouldSkip(name: "main.swift", relativePath: "Sources/main.swift"))

    store.saveRules([bigBuildArtifact])
    let reloaded = FileRulesStore(suiteName: suiteName).loadRules()
    #expect(reloaded == [bigBuildArtifact])

    #expect(AsciiFileExtensions.defaultList.count == 23)
    #expect(store.isAsciiTransferFile("README.MD"))
    #expect(store.isAsciiTransferFile("/var/www/index.html"))
    #expect(store.isAsciiTransferFile("schema.sql"))
    #expect(!store.isAsciiTransferFile("archive.zip"))
    #expect(!store.isAsciiTransferFile("Makefile"))
}

@Test func syncEngineRespectsEnabledSkipRulesAndIgnorePatterns() throws {
    let baseDate = Date(timeIntervalSince1970: 1_760_000_000)
    let localRoot = URL(fileURLWithPath: "/local/project")
    let localFiles: [LocalFileItem] = [
        LocalFileItem(relativePath: "src/app.swift", fileURL: localRoot.appendingPathComponent("src/app.swift"), isDirectory: false, size: 1200, modified: baseDate),
        LocalFileItem(relativePath: ".git/config", fileURL: localRoot.appendingPathComponent(".git/config"), isDirectory: false, size: 300, modified: baseDate),
        LocalFileItem(relativePath: "dist/bundle.js", fileURL: localRoot.appendingPathComponent("dist/bundle.js"), isDirectory: false, size: 5000, modified: baseDate),
        LocalFileItem(relativePath: "assets/video.mp4", fileURL: localRoot.appendingPathComponent("assets/video.mp4"), isDirectory: false, size: 5_000_000, modified: baseDate),
        LocalFileItem(relativePath: "notes.txt", fileURL: localRoot.appendingPathComponent("notes.txt"), isDirectory: false, size: 200, modified: baseDate)
    ]
    let remoteFiles: [FileEntry] = [
        FileEntry(name: "orphan.swp", path: "/remote/project/orphan.swp", isDirectory: false, size: 400, modified: baseDate),
        FileEntry(name: "keep-orphan.txt", path: "/remote/project/keep-orphan.txt", isDirectory: false, size: 400, modified: baseDate)
    ]

    let rules: [SkipRule] = [
        SkipRule(name: "Git", isEnabled: true, matchMode: .any, scope: .all, predicates: [
            RulePredicate(field: .name, op: .is, value: ".git")
        ]),
        SkipRule(name: "Large Files", isEnabled: true, matchMode: .all, scope: .transfersAndSync, predicates: [
            RulePredicate(field: .sizeBytes, op: .greaterThan, value: "1 MB")
        ]),
        SkipRule(name: "Vim Swap", isEnabled: true, matchMode: .all, scope: .transfersAndSync, predicates: [
            RulePredicate(field: .name, op: .matchesGlob, value: "*.swp")
        ]),
        SkipRule(name: "Disabled txt rule", isEnabled: false, matchMode: .all, scope: .all, predicates: [
            RulePredicate(field: .fileExtension, op: .is, value: "txt")
        ])
    ]

    let plan = SyncEngine.generatePlan(
        localRoot: localRoot,
        localFiles: localFiles,
        remoteRoot: "/remote/project",
        remoteFiles: remoteFiles,
        direction: .localToRemote,
        deleteOrphans: true,
        ignorePatterns: ["dist"],
        skipRules: rules
    )

    let uploaded = Set(plan.uploadItems.map(\.relativePath))
    #expect(uploaded == ["src/app.swift", "notes.txt"])
    let deleted = Set(plan.deleteItems.map(\.relativePath))
    #expect(deleted == ["keep-orphan.txt"])
}

@Test func transcriptRedactorSanitizesSecretsAndLoggerEvictsBoundedBuffer() async throws {
    let secrets = [
        "BasicSecretToken==",
        "BearerJwtPayloadSecret",
        "DeadBeefAwsSigSecret",
        "AzureSharedKeySecret==",
        "AmzSecTokenSecret",
        "AmzHdrSigSecret",
        "XAuthTokenSecretVal",
        "XAuthKeySecretVal",
        "QuerySigSecret",
        "QueryTokenSecret",
        "QueryPassSecret",
        "UserInfoSecretPass!",
        "FtpSecretPass99",
        "KeyPassphraseSecret88",
        "QuotedPassSecret123",
        "QuotedJwtSecretVal",
        "AzureSasJsonSecret",
        "XAuthEqTokSecret",
        "XAuthEqKeySecret",
        "DigestNonceSecretDeadBeef"
    ]

    let rawLog = """
    Authorization: Basic \(secrets[0])
    Authorization: Bearer \(secrets[1])
    Authorization: AWS4-HMAC-SHA256 Credential=AKIA123/20261125/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=\(secrets[2])
    Authorization: SharedKey myacct:\(secrets[3])
    Authorization: Digest username="alice", realm="dav", response="\(secrets[19])"
    curl -H 'Authorization: Digest username="alice", response="\(secrets[19])"'
    X-Amz-Security-Token: \(secrets[4])
    X-Amz-Signature: \(secrets[5])
    X-Auth-Token: \(secrets[6])
    X-Auth-Key: \(secrets[7])
    X-Auth-Token=\(secrets[17])&X-Auth-Key=\(secrets[18])
    password="\(secrets[14])" token='\(secrets[15])'
    {"query":"sig=\(secrets[16])&sv=2022"}
    GET https://bucket.s3.amazonaws.com/f.zip?X-Amz-Signature=\(secrets[8])&X-Amz-Security-Token=\(secrets[4])&sig=\(secrets[8])&token=\(secrets[9])&password=\(secrets[10])&keep=visible
    Connecting sftp://deploy:\(secrets[11])@prod.example.com:22/var/www
    Connecting sftp://deploy@readonly.example.com:22/var/www
    > PASS \(secrets[12])
    Please pass the public key path
    Enter passphrase for key '/Users/dev/.ssh/id_ed25519': \(secrets[13])
    Authorization: Bearer 
    Host: safe-next-header.example.com
    X-Amz-Security-Token: 
    Content-Type: text/plain
    password: 
    Accept: application/json
    """

    let sanitized = TranscriptRedactor.sanitize(rawLog)
    for secret in secrets {
        #expect(!sanitized.contains(secret), "Secret leaked: \(secret)")
    }
    #expect(sanitized.contains("Authorization: Basic [REDACTED]"))
    #expect(sanitized.contains("Authorization: Bearer [REDACTED]"))
    #expect(sanitized.contains("Authorization: AWS4-HMAC-SHA256 [REDACTED]"))
    #expect(sanitized.contains("Authorization: SharedKey [REDACTED]"))
    #expect(sanitized.contains("Authorization: Digest [REDACTED]"))
    #expect(sanitized.contains("curl -H 'Authorization: Digest [REDACTED]'"))
    #expect(sanitized.contains("X-Auth-Token=[REDACTED]&X-Auth-Key=[REDACTED]"))
    #expect(sanitized.contains("password=\"[REDACTED]\" token='[REDACTED]'"))
    #expect(sanitized.contains("{\"query\":\"sig=[REDACTED]&sv=2022\"}"))
    #expect(sanitized.contains("sftp://deploy:***@prod.example.com:22/var/www"))
    #expect(sanitized.contains("sftp://deploy@readonly.example.com:22/var/www"))
    #expect(sanitized.contains("&keep=visible"))
    #expect(sanitized.contains("> PASS [REDACTED]"))
    #expect(sanitized.contains("Please pass the public key path"))
    #expect(sanitized.contains("Host: safe-next-header.example.com"))
    #expect(sanitized.contains("Content-Type: text/plain"))
    #expect(sanitized.contains("Accept: application/json"))

    // Bounded ring buffer eviction & thread-safe concurrent appends
    let logger = TranscriptLogger(maxEntries: 3)
    logger.append(connectionName: "Prod", protocolTitle: "FTP", category: .connect, message: "PASS secret123")
    logger.append(connectionName: "Prod", protocolTitle: "FTP", category: .command, message: "LIST /var/www")
    logger.append(connectionName: "Prod", protocolTitle: "FTP", category: .transfer, message: "Uploaded index.html")
    logger.append(connectionName: "Prod", protocolTitle: "FTP", category: .error, message: "Timeout on sftp://u:pw@h/a")

    #expect(logger.count == 3)
    let all = logger.entries()
    #expect(all.map { $0.category } == [.command, .transfer, .error])
    #expect(all.last?.message.contains("pw") == false)
    #expect(logger.entries(category: .transfer).count == 1)
    #expect(logger.entries(search: "index.html").count == 1)
    #expect(logger.exportText().contains("[TRANSFER] Uploaded index.html"))

    logger.clear()
    #expect(logger.count == 0)

    await withTaskGroup(of: Void.self) { group in
        for i in 0..<25 {
            group.addTask {
                logger.append(connectionName: "Concurrent", protocolTitle: "SFTP", category: .transfer, message: "chunk \(i)")
            }
        }
    }
    #expect(logger.count == 3)
}

@Test func dropletExporterCreatesBundleAndURLCommandsRoundTrip() throws {
    let profileId = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
    let profile = ServerProfile(
        id: profileId,
        name: "Prod Web",
        host: "web.example.com",
        port: 22,
        username: "deploy",
        protocolKind: .sftp,
        initialPath: "/var/www"
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-droplet-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let appURL = tempDir.appendingPathComponent("Prod Web.app", isDirectory: true)
    try DropletExporter.exportDroplet(for: profile, remotePath: "/var/www/my site", destinationAppURL: appURL)

    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
    let execURL = appURL.appendingPathComponent("Contents/MacOS/\(DropletExporter.dropletExecutableName)")
    #expect(FileManager.default.fileExists(atPath: plistURL.path))
    #expect(FileManager.default.fileExists(atPath: execURL.path))

    let plistData = try Data(contentsOf: plistURL)
    let plistObj = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    #expect(plistObj?["CFBundleIdentifier"] as? String == "com.aethernative.AetherTransfer.droplet.123456781234")
    #expect(plistObj?["CFBundleExecutable"] as? String == DropletExporter.dropletExecutableName)
    let docTypes = plistObj?["CFBundleDocumentTypes"] as? [[String: Any]]
    let utis = docTypes?.first?["LSItemContentTypes"] as? [String]
    #expect(utis == ["public.item", "public.data", "public.folder"])

    let attrs = try FileManager.default.attributesOfItem(atPath: execURL.path)
    let perms = attrs[.posixPermissions] as? Int
    #expect(perms == 0o755)

    // Verify shell syntax passes `/bin/sh -n`
    let syntaxProc = Process()
    syntaxProc.executableURL = URL(fileURLWithPath: "/bin/sh")
    syntaxProc.arguments = ["-n", execURL.path]
    try syntaxProc.run()
    syntaxProc.waitUntilExit()
    #expect(syntaxProc.terminationStatus == 0)

    // Execute launcher script with a stubbed `open` binary in PATH to verify safe escaping & URL generation
    let stubBinDir = tempDir.appendingPathComponent("stub-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: stubBinDir, withIntermediateDirectories: true)
    let capturedArgsFile = tempDir.appendingPathComponent("captured_open_args.txt")
    let stubOpenURL = stubBinDir.appendingPathComponent("open")
    let stubScript = """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(capturedArgsFile.path)"
    """
    try Data(stubScript.utf8).write(to: stubOpenURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubOpenURL.path)

    let trickyFile = tempDir.appendingPathComponent("测试 file'&?$100.txt")
    try Data("hi".utf8).write(to: trickyFile)

    let runProc = Process()
    runProc.executableURL = execURL
    runProc.arguments = ["-psn_0_12345", trickyFile.path]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(stubBinDir.path):/usr/bin:/bin"
    runProc.environment = env
    try runProc.run()
    runProc.waitUntilExit()
    #expect(runProc.terminationStatus == 0)

    let capturedLines = try String(contentsOf: capturedArgsFile, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }
    #expect(capturedLines.count == 3)
    #expect(capturedLines[0] == "-b")
    #expect(capturedLines[1] == DropletExporter.mainBundleIdentifier)
    let emittedURL = try #require(URL(string: capturedLines[2]))
    let roundTripped = try AetherURLCommand.parse(emittedURL)
    guard case .upload(let parsedId, let parsedRemote, let parsedFiles) = roundTripped else {
        Issue.record("Expected .upload command from droplet script")
        return
    }
    #expect(parsedId == profileId)
    #expect(parsedRemote == "/var/www/my site")
    #expect(parsedFiles.map { $0.standardizedFileURL.path } == [trickyFile.standardizedFileURL.path])

    // Additional AetherURLCommand.parse tests: comma-separated files & connect URLs (stripping password!)
    let commaURL = URL(string: "aethertransfer://upload?profileId=\(profileId.uuidString)&remotePath=/uploads&files=/tmp/a.txt,/tmp/b.txt")!
    let commaCmd = try AetherURLCommand.parse(commaURL, additionalLocalURLs: [URL(fileURLWithPath: "/tmp/c.txt")])
    #expect(commaCmd == .upload(
        profileId: profileId,
        remotePath: "/uploads",
        localURLs: [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.txt")
        ]
    ))

    let sftpURL = URL(string: "sftp://alice:SuperSecretURLPass!@sftp.example.com:2222/srv/data")!
    let connectCmd = try AetherURLCommand.parse(sftpURL)
    guard case .connect(let parsedProfile) = connectCmd else {
        Issue.record("Expected .connect command")
        return
    }
    #expect(parsedProfile.protocolKind == .sftp)
    #expect(parsedProfile.username == "alice")
    #expect(parsedProfile.host == "sftp.example.com")
    #expect(parsedProfile.port == 2222)
    #expect(parsedProfile.initialPath == "/srv/data")
    let encodedProfileJSON = String(decoding: try JSONEncoder().encode(parsedProfile), as: UTF8.self)
    #expect(!encodedProfileJSON.contains("SuperSecretURLPass!"))

    let bookmarkConnectURL = URL(string: "aethertransfer://connect?profileId=\(profileId.uuidString)")!
    #expect(try AetherURLCommand.parse(bookmarkConnectURL, savedProfiles: [profile]) == .connect(profile))
    #expect(try AetherURLCommand.parse(bookmarkConnectURL) == .connectProfile(profileId: profileId))
}

@Test func sshConfigProxyJumpAndKnownHostsManager() throws {
    let config = """
    Host prod-app
        HostName 10.0.10.5
        User deploy
        Port = 2222
        IdentityFile ~/.ssh/id_prod
        ProxyJump bastion@jump.example.com:2200

    Host direct-host
        HostName 10.0.10.6
        ProxyJump none
    """
    let entries = SSHConfigParser.parse(config)
    #expect(entries.count == 2)
    #expect(entries[0].port == 2222)
    #expect(entries[0].proxyJump == "bastion@jump.example.com:2200")
    #expect(entries[1].proxyJump == nil)

    let rawHostKey = Data("ssh-ed25519-test-host-key-bytes".utf8).base64EncodedString()
    let expectedFP = RemoteClient.fingerprint(rawHostKey)
    #expect(KnownHostsManager.formattedFingerprint(rawHostKey) == expectedFP)
    #expect(KnownHostsManager.formattedFingerprint("ssh-ed25519 \(rawHostKey) root@host") == expectedFP)

    var profiles = [
        ServerProfile(name: "Trusted Server", host: "trusted.example.com", port: 22, username: "u", protocolKind: .sftp, trustedHostKey: rawHostKey),
        ServerProfile(name: "Untrusted Server", host: "new.example.com", port: 22, username: "u", protocolKind: .sftp, trustedHostKey: nil)
    ]
    let trusted = KnownHostsManager.listTrustedHosts(from: profiles)
    #expect(trusted.count == 1)
    #expect(trusted[0].profileId == profiles[0].id)
    #expect(trusted[0].fingerprint == expectedFP)

    let revoked = KnownHostsManager.revokeHostKey(profileId: profiles[0].id, in: &profiles)
    #expect(revoked == true)
    #expect(profiles[0].trustedHostKey == nil)
    #expect(KnownHostsManager.listTrustedHosts(from: profiles).isEmpty)
}

@Test func transferQueueEtaMoveToTopRetryAllFailedAndFilter() async throws {
    struct SimulatedFailure: Error {}

    // 1. ETA calculation during active progress
    let etaQueue = TransferQueueManager(maxConcurrentTransfers: 1)
    let progressObserved = AsyncStream<Double?>.makeStream()
    let etaGate = AsyncStream<Void>.makeStream()

    let etaId = etaQueue.enqueue(
        name: "archive.tar.gz",
        direction: .upload,
        copyURLOnComplete: true,
        remoteURLString: "https://cdn.example.com/archive.tar.gz"
    ) { progress in
        try await Task.sleep(nanoseconds: 60_000_000)
        progress(TransferProgress(completed: 500_000, total: 1_000_000))
        let currentETA = etaQueue.items.first(where: { $0.name == "archive.tar.gz" })?.etaSeconds
        progressObserved.continuation.yield(currentETA)
        for await _ in etaGate.stream {
            break
        }
    }

    var observedETA: Double?
    for await eta in progressObserved.stream {
        observedETA = eta
        break
    }
    #expect(observedETA != nil)
    #expect((observedETA ?? -1) >= 0)
    let inProgressItem = etaQueue.items.first(where: { $0.id == etaId })
    #expect(inProgressItem?.copyURLOnComplete == true)
    #expect(inProgressItem?.remoteURLString == "https://cdn.example.com/archive.tar.gz")

    etaGate.continuation.yield(())
    etaGate.continuation.finish()
    try await Task.sleep(nanoseconds: 80_000_000)
    #expect(etaQueue.items.first(where: { $0.id == etaId })?.state == .completed)
    #expect(etaQueue.items.first(where: { $0.id == etaId })?.etaSeconds == nil)

    // 2. moveToTop prioritizes queued task both in items and execution order
    let orderQueue = TransferQueueManager(maxConcurrentTransfers: 1)
    let executionOrder = OSAllocatedUnfairLock(initialState: [String]())
    let releaseFirst = AsyncStream<Void>.makeStream()
    let firstStarted = AsyncStream<Void>.makeStream()

    _ = orderQueue.enqueue(name: "A-running", direction: .upload) { _ in
        firstStarted.continuation.yield(())
        for await _ in releaseFirst.stream {
            break
        }
    }
    for await _ in firstStarted.stream { break }

    let idB = orderQueue.enqueue(name: "B-second", direction: .upload) { _ in
        executionOrder.withLock { $0.append("B") }
    }
    let idC = orderQueue.enqueue(name: "C-prioritized", direction: .upload) { _ in
        executionOrder.withLock { $0.append("C") }
    }

    orderQueue.moveToTop(id: idC)
    #expect(orderQueue.items.first?.id == idC)
    #expect(orderQueue.filteredItems(.active).count == 3)

    releaseFirst.continuation.yield(())
    releaseFirst.continuation.finish()

    try await Task.sleep(nanoseconds: 150_000_000)
    let capturedOrder = executionOrder.withLock { $0 }
    #expect(capturedOrder == ["C", "B"])
    _ = idB

    // 3. retryAllFailed and TransferFilter
    let retryQueue = TransferQueueManager(maxConcurrentTransfers: 2)
    let shouldFail = OSAllocatedUnfairLock(initialState: true)

    let fail1 = retryQueue.enqueue(name: "f1.bin", direction: .download) { _ in
        let fail = shouldFail.withLock { $0 }
        if fail { throw SimulatedFailure() }
    }
    let fail2 = retryQueue.enqueue(name: "f2.bin", direction: .download) { _ in
        let fail = shouldFail.withLock { $0 }
        if fail { throw SimulatedFailure() }
    }
    retryQueue.pause()
    let cancelledId = retryQueue.enqueue(name: "c1.bin", direction: .download) { _ in }
    retryQueue.cancel(id: cancelledId)
    retryQueue.resume()

    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(retryQueue.filteredItems(.failed).count == 2)
    #expect(retryQueue.filteredItems(.cancelled).count == 1)
    #expect(retryQueue.filteredItems(.all).count == 3)

    shouldFail.withLock { $0 = false }
    let retried = retryQueue.retryAllFailed()
    #expect(retried == 2)

    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(retryQueue.filteredItems(.completed).count == 2)
    #expect(retryQueue.filteredItems(.failed).isEmpty)
    #expect(retryQueue.filteredItems(.cancelled).count == 1)
    _ = (fail1, fail2)
}
