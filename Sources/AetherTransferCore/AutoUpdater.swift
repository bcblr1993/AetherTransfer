import Foundation
import CryptoKit
import Darwin

public enum AutoUpdateError: Error, LocalizedError, Sendable, Equatable {
    case invalidFeedURL
    case invalidManifest(String)
    case networkError(String)
    case insecureDownloadURL
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidAppBundle(String)
    case codeSignatureInvalid(String)
    case installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            return L10n.tr("更新源地址无效。", "Invalid update feed URL.")
        case .invalidManifest(let detail):
            return L10n.tr("更新清单格式无效：\(detail)", "Invalid update manifest: \(detail)")
        case .networkError(let detail):
            return L10n.tr("检查或下载更新失败：\(detail)", "Failed to check or download update: \(detail)")
        case .insecureDownloadURL:
            return L10n.tr("拒绝不安全的更新下载地址（必须使用 HTTPS）。", "Rejected insecure update download URL (HTTPS required).")
        case .checksumMismatch(let expected, let actual):
            return L10n.tr("安装包 SHA-256 校验失败（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…），已销毁临时文件。",
                           "Update package SHA-256 mismatch (expected \(expected.prefix(12))..., got \(actual.prefix(12))...). Temporary file discarded.")
        case .extractionFailed(let detail):
            return L10n.tr("解压更新包失败：\(detail)", "Failed to extract update archive: \(detail)")
        case .invalidAppBundle(let detail):
            return L10n.tr("更新包内的应用程序包无效：\(detail)", "Invalid application bundle in update archive: \(detail)")
        case .codeSignatureInvalid(let detail):
            return L10n.tr("更新包代码签名校验未通过：\(detail)", "Update bundle code signature verification failed: \(detail)")
        case .installationFailed(let detail):
            return L10n.tr("安装更新失败：\(detail)", "Failed to install update: \(detail)")
        }
    }
}

public struct SemanticVersion: Comparable, Hashable, Codable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(parsing raw: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if let plusIndex = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIndex])
        }
        let parts = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count >= 2 && core.count <= 3 else { return nil }
        guard let maj = Int(core[0]), let min = Int(core[1]), maj >= 0, min >= 0 else { return nil }
        let pat: Int
        if core.count == 3 {
            guard let p = Int(core[2]), p >= 0 else { return nil }
            pat = p
        } else {
            pat = 0
        }
        let pre: String? = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        self.major = maj
        self.minor = min
        self.patch = pat
        self.prerelease = pre
    }

    public var description: String {
        if let prerelease, !prerelease.isEmpty {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            // Prerelease is lower than normal release of same major.minor.patch
            return true
        case (nil, .some):
            return false
        case (.some(let lPre), .some(let rPre)):
            return lPre.localizedStandardCompare(rPre) == .orderedAscending
        }
    }
}

public struct UpdateRelease: Codable, Hashable, Sendable {
    public let version: String
    public let buildNumber: String
    public let publishedAt: String
    public let downloadURL: String
    public let sha256: String
    public let sizeBytes: Int64
    public let minimumSystemVersion: String
    public let releaseNotesZh: String
    public let releaseNotesEn: String

    public init(
        version: String,
        buildNumber: String = "1",
        publishedAt: String,
        downloadURL: String,
        sha256: String,
        sizeBytes: Int64,
        minimumSystemVersion: String = "26.0",
        releaseNotesZh: String,
        releaseNotesEn: String
    ) {
        self.version = version
        self.buildNumber = buildNumber
        self.publishedAt = publishedAt
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesZh = releaseNotesZh
        self.releaseNotesEn = releaseNotesEn
    }

    public var localizedReleaseNotes: String {
        L10n.isEnglish ? (releaseNotesEn.isEmpty ? releaseNotesZh : releaseNotesEn) : (releaseNotesZh.isEmpty ? releaseNotesEn : releaseNotesZh)
    }

    public func validate(allowLocalFileURL: Bool = false) throws {
        guard SemanticVersion(parsing: version) != nil else {
            throw AutoUpdateError.invalidManifest("Invalid version string '\(version)'")
        }
        guard sizeBytes > 0 else {
            throw AutoUpdateError.invalidManifest("sizeBytes must be positive")
        }
        let cleanHash = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanHash.count == 64,
              cleanHash.allSatisfy({ $0.isHexDigit }) else {
            throw AutoUpdateError.invalidManifest("sha256 must be 64 hexadecimal characters")
        }
        guard let url = URL(string: downloadURL), let scheme = url.scheme?.lowercased() else {
            throw AutoUpdateError.invalidManifest("Invalid downloadURL")
        }
        if scheme != "https" && !(allowLocalFileURL && scheme == "file") {
            throw AutoUpdateError.insecureDownloadURL
        }
    }
}

public struct UpdateManifest: Codable, Hashable, Sendable {
    public let appName: String
    public let bundleIdentifier: String
    public let latest: UpdateRelease

    public init(
        appName: String = "AetherTransfer",
        bundleIdentifier: String = "com.aethernative.AetherTransfer",
        latest: UpdateRelease
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.latest = latest
    }

    public func validate(expectedBundleIdentifier: String = "com.aethernative.AetherTransfer", allowLocalFileURL: Bool = false) throws {
        guard bundleIdentifier == expectedBundleIdentifier else {
            throw AutoUpdateError.invalidManifest("Bundle ID mismatch: \(bundleIdentifier)")
        }
        try latest.validate(allowLocalFileURL: allowLocalFileURL)
    }
}

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(UpdateRelease)
    case downloading(release: UpdateRelease, completedBytes: Int64, totalBytes: Int64, progress: Double)
    case verifying(release: UpdateRelease)
    case readyToInstall(release: UpdateRelease, stagedAppURL: URL)
    case installing(release: UpdateRelease)
    case failed(String)
}

public enum AutoUpdater {
    public static let defaultFeedURLString = "https://www.aethernative.com/apps/aethertransfer/appcast.json"
    public static let githubLatestReleaseAPIURLString = "https://api.github.com/repos/bcblr1993/AetherTransfer/releases/latest"
    public static let expectedBundleIdentifier = "com.aethernative.AetherTransfer"

    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        if let ver = bundle.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
            return ver
        }
        return "0.1.0"
    }

    public static func currentBuildNumber(bundle: Bundle = .main) -> String {
        if let build = bundle.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        return "2026102101"
    }

    public static func resolvedFeedURL(bundle: Bundle = .main) throws -> URL {
        if let envURL = ProcessInfo.processInfo.environment["AETHER_UPDATE_FEED_URL"],
           !envURL.isEmpty,
           let url = URL(string: envURL) {
            return url
        }
        if let plistURL = bundle.infoDictionary?["ATUpdateFeedURL"] as? String,
           !plistURL.isEmpty,
           let url = URL(string: plistURL) {
            return url
        }
        guard let url = URL(string: defaultFeedURLString) else {
            throw AutoUpdateError.invalidFeedURL
        }
        return url
    }

    public static func parseManifest(from data: Data, allowLocalFileURL: Bool = false) throws -> UpdateManifest {
        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(UpdateManifest.self, from: data) {
            try manifest.validate(expectedBundleIdentifier: expectedBundleIdentifier, allowLocalFileURL: allowLocalFileURL)
            return manifest
        }
        // Fallback: try parsing GitHub Releases API JSON format
        if let ghManifest = try? parseGitHubReleaseManifest(from: data, allowLocalFileURL: allowLocalFileURL) {
            return ghManifest
        }
        do {
            let manifest = try decoder.decode(UpdateManifest.self, from: data)
            try manifest.validate(expectedBundleIdentifier: expectedBundleIdentifier, allowLocalFileURL: allowLocalFileURL)
            return manifest
        } catch {
            throw AutoUpdateError.invalidManifest(error.localizedDescription)
        }
    }

    private struct GitHubReleaseDTO: Decodable {
        let tag_name: String
        let published_at: String?
        let body: String?
        let assets: [GitHubAssetDTO]
    }

    private struct GitHubAssetDTO: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64
        let digest: String?
    }

    public static func parseGitHubReleaseManifest(from data: Data, allowLocalFileURL: Bool = false) throws -> UpdateManifest {
        let dto = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        guard let zipAsset = dto.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
            throw AutoUpdateError.invalidManifest("No .zip asset found in GitHub release")
        }
        var cleanVer = dto.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanVer.hasPrefix("v") || cleanVer.hasPrefix("V") {
            cleanVer.removeFirst()
        }
        var extractedSHA256 = ""
        if let digest = zipAsset.digest, digest.lowercased().hasPrefix("sha256:") {
            extractedSHA256 = String(digest.dropFirst("sha256:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let body = dto.body {
            // Look for 64-character hex SHA-256 in release notes body
            let tokens = body.components(separatedBy: CharacterSet.alphanumerics.inverted)
            if let hex64 = tokens.first(where: { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) {
                extractedSHA256 = hex64.lowercased()
            }
        }
        let notes = dto.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "AetherTransfer v\(cleanVer)"
        let release = UpdateRelease(
            version: cleanVer,
            buildNumber: cleanVer,
            publishedAt: dto.published_at ?? "",
            downloadURL: zipAsset.browser_download_url,
            sha256: extractedSHA256,
            sizeBytes: zipAsset.size,
            minimumSystemVersion: "26.0",
            releaseNotesZh: notes,
            releaseNotesEn: notes
        )
        let manifest = UpdateManifest(latest: release)
        try manifest.validate(expectedBundleIdentifier: expectedBundleIdentifier, allowLocalFileURL: allowLocalFileURL)
        return manifest
    }

    public static func evaluateUpdate(currentVersion: String, manifest: UpdateManifest) throws -> UpdateRelease? {
        guard let currentSemVer = SemanticVersion(parsing: currentVersion) else {
            throw AutoUpdateError.invalidManifest("Invalid current version \(currentVersion)")
        }
        guard let latestSemVer = SemanticVersion(parsing: manifest.latest.version) else {
            throw AutoUpdateError.invalidManifest("Invalid latest version \(manifest.latest.version)")
        }
        return latestSemVer > currentSemVer ? manifest.latest : nil
    }

    public static func fetchManifest(from feedURL: URL, allowLocalFileURL: Bool = false) async throws -> UpdateManifest {
        let scheme = feedURL.scheme?.lowercased()
        guard scheme == "https" || (allowLocalFileURL && scheme == "file") else {
            throw AutoUpdateError.insecureDownloadURL
        }
        let data: Data
        if scheme == "file" {
            do {
                data = try Data(contentsOf: feedURL)
            } catch {
                throw AutoUpdateError.networkError(error.localizedDescription)
            }
        } else {
            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if feedURL.absoluteString == defaultFeedURLString,
                       let fallbackURL = URL(string: githubLatestReleaseAPIURLString) {
                        return try await fetchManifest(from: fallbackURL, allowLocalFileURL: allowLocalFileURL)
                    }
                    throw AutoUpdateError.networkError("HTTP \(http.statusCode)")
                }
                data = responseData
            } catch let err as AutoUpdateError {
                throw err
            } catch {
                if feedURL.absoluteString == defaultFeedURLString,
                   let fallbackURL = URL(string: githubLatestReleaseAPIURLString) {
                    return try await fetchManifest(from: fallbackURL, allowLocalFileURL: allowLocalFileURL)
                }
                throw AutoUpdateError.networkError(error.localizedDescription)
            }
        }
        return try parseManifest(from: data, allowLocalFileURL: allowLocalFileURL)
    }

    public static func computeSHA256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func downloadAndStageUpdate(
        release: UpdateRelease,
        stagingRoot: URL? = nil,
        allowLocalFileURL: Bool = false,
        requireCodeSignature: Bool = true,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        try release.validate(allowLocalFileURL: allowLocalFileURL)
        guard let downloadURL = URL(string: release.downloadURL) else {
            throw AutoUpdateError.invalidManifest("Invalid downloadURL")
        }

        let fm = FileManager.default
        let baseDir = stagingRoot ?? fm.temporaryDirectory.appendingPathComponent("AetherTransferUpdate-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: baseDir.path) {
            try? fm.removeItem(at: baseDir)
        }
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let archiveFile = baseDir.appendingPathComponent("update-\(release.version).zip")

        // Download archive
        if downloadURL.isFileURL {
            guard allowLocalFileURL else { throw AutoUpdateError.insecureDownloadURL }
            try fm.copyItem(at: downloadURL, to: archiveFile)
            let attrs = try fm.attributesOfItem(atPath: archiveFile.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? release.sizeBytes
            progress(size, max(size, release.sizeBytes))
        } else {
            var request = URLRequest(url: downloadURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw AutoUpdateError.networkError("HTTP \(http.statusCode)")
            }
            let expectedTotal = response.expectedContentLength > 0 ? response.expectedContentLength : release.sizeBytes
            fm.createFile(atPath: archiveFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let writeHandle = try FileHandle(forWritingTo: archiveFile)
            defer { try? writeHandle.close() }

            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var received: Int64 = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try writeHandle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(received, expectedTotal)
                }
            }
            if !buffer.isEmpty {
                try writeHandle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll()
                progress(received, expectedTotal)
            }
            try writeHandle.synchronize()
        }

        try Task.checkCancellation()

        // Verify SHA-256 digest
        let actualHash = try computeSHA256Hex(of: archiveFile).lowercased()
        let expectedHash = release.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard actualHash == expectedHash else {
            try? fm.removeItem(at: baseDir)
            throw AutoUpdateError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }

        // Unpack archive into unpacked/ directory
        let unpackDir = baseDir.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try extractZipArchive(at: archiveFile, to: unpackDir)

        // Locate .app bundle inside unpackDir
        let contents = try fm.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        guard let stagedApp = contents.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: baseDir)
            throw AutoUpdateError.invalidAppBundle("Archive does not contain a top-level .app bundle")
        }

        // Verify Info.plist inside stagedApp
        let infoPlistURL = stagedApp.appendingPathComponent("Contents/Info.plist")
        guard fm.fileExists(atPath: infoPlistURL.path),
              let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            try? fm.removeItem(at: baseDir)
            throw AutoUpdateError.invalidAppBundle("Missing or unreadable Contents/Info.plist")
        }

        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        guard bundleID == expectedBundleIdentifier else {
            try? fm.removeItem(at: baseDir)
            throw AutoUpdateError.invalidAppBundle("Unexpected CFBundleIdentifier '\(bundleID)'")
        }

        let bundleVer = plist["CFBundleShortVersionString"] as? String ?? ""
        guard SemanticVersion(parsing: bundleVer) == SemanticVersion(parsing: release.version) else {
            try? fm.removeItem(at: baseDir)
            throw AutoUpdateError.invalidAppBundle("Bundle version '\(bundleVer)' does not match release '\(release.version)'")
        }

        // Verify code signature
        if requireCodeSignature {
            try verifyCodeSignature(of: stagedApp)
        }

        return stagedApp
    }

    public static func extractZipArchive(at archiveURL: URL, to destinationDir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationDir.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto exit \(process.terminationStatus)"
            throw AutoUpdateError.extractionFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func verifyCodeSignature(of appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "codesign exit \(process.terminationStatus)"
            throw AutoUpdateError.codeSignatureInvalid(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Generates an atomic shell script that waits for the running process to exit, swaps the `.app` bundle, and relaunches.
    public static func generateRelaunchScript(
        stagedAppURL: URL,
        targetAppURL: URL,
        processIdentifier: Int32,
        relaunch: Bool = true
    ) -> String {
        let stagedEscaped = ShellEscape.singleQuoted(stagedAppURL.path)
        let targetEscaped = ShellEscape.singleQuoted(targetAppURL.path)
        let backupEscaped = ShellEscape.singleQuoted(targetAppURL.path + ".rollback-\(processIdentifier)")
        let stagingRootEscaped = ShellEscape.singleQuoted(stagedAppURL.deletingLastPathComponent().deletingLastPathComponent().path)
        let openCmd = relaunch ? "/usr/bin/open -n \(targetEscaped)" : ":"

        return """
        #!/bin/sh
        set -eu
        PID=\(processIdentifier)
        STAGED=\(stagedEscaped)
        TARGET=\(targetEscaped)
        BACKUP=\(backupEscaped)
        STAGING_ROOT=\(stagingRootEscaped)

        # Wait up to 15 seconds for the current app process to exit
        ATTEMPTS=0
        while kill -0 "$PID" 2>/dev/null; do
            ATTEMPTS=$((ATTEMPTS + 1))
            if [ "$ATTEMPTS" -ge 150 ]; then
                break
            fi
            sleep 0.1
        done

        rm -rf "$BACKUP"
        if [ -d "$TARGET" ]; then
            mv "$TARGET" "$BACKUP"
        fi

        if mv "$STAGED" "$TARGET"; then
            rm -rf "$BACKUP"
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            rm -rf "$STAGING_ROOT" 2>/dev/null || true
            \(openCmd)
        else
            if [ -d "$BACKUP" ] && [ ! -d "$TARGET" ]; then
                mv "$BACKUP" "$TARGET"
            fi
            exit 1
        fi
        """
    }

    public static func installAndRelaunch(
        stagedAppURL: URL,
        targetAppURL: URL? = nil,
        relaunch: Bool = true,
        terminateApp: () -> Void
    ) throws {
        let destinationURL = targetAppURL ?? Bundle.main.bundleURL
        guard destinationURL.pathExtension == "app" else {
            throw AutoUpdateError.installationFailed(
                L10n.tr("当前进程未从标准 .app 包运行（路径：\(destinationURL.path)），请使用打包后的 AetherTransfer.app 执行应用内更新。",
                        "Current process is not running from a .app bundle (\(destinationURL.path)). Please run from AetherTransfer.app to install updates.")
            )
        }

        let pid = getpid()
        let scriptContent = generateRelaunchScript(
            stagedAppURL: stagedAppURL,
            targetAppURL: destinationURL,
            processIdentifier: pid,
            relaunch: relaunch
        )

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("aether-updater-\(pid)-\(UUID().uuidString).sh")
        try scriptContent.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        terminateApp()
    }
}

public enum ShellEscape {
    /// Safely wraps any string in single quotes for POSIX sh, escaping embedded single quotes as `'\''`.
    public static func singleQuoted(_ raw: String) -> String {
        let sanitized = raw.replacingOccurrences(of: "\0", with: "")
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for embedding inside an AppleScript double-quoted string literal.
    public static func appleScriptQuoted(_ raw: String) -> String {
        let sanitized = raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(sanitized)\""
    }
}
