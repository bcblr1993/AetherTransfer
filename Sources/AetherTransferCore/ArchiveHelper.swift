import Foundation

public enum ArchiveError: Error, LocalizedError, Sendable {
    case compressionFailed(String)
    case extractionFailed(String)
    case unsafeArchive(String)
    case emptySource

    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let msg):
            return L10n.tr("压缩文件失败：\(msg)", "Archive compression failed: \(msg)")
        case .extractionFailed(let msg):
            return L10n.tr("解压文件失败：\(msg)", "Archive extraction failed: \(msg)")
        case .unsafeArchive(let msg):
            return L10n.tr("压缩包包含不安全的路径或符号链接：\(msg)", "Unsafe archive entry rejected: \(msg)")
        case .emptySource:
            return L10n.tr("未指定需要压缩的文件。", "No source files specified for archiving.")
        }
    }
}

public enum ArchiveHelper {
    public static func createZip(from sourceURLs: [URL], destinationZipURL: URL) throws {
        guard !sourceURLs.isEmpty else { throw ArchiveError.emptySource }

        let destDir = destinationZipURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
            try FileManager.default.removeItem(at: destinationZipURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")

        if sourceURLs.count == 1, let singleURL = sourceURLs.first {
            // Single file or directory: preserve root
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", singleURL.path, destinationZipURL.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "未知错误"
                throw ArchiveError.compressionFailed(errMsg)
            }
        } else {
            // Multiple items: stage into a temporary directory
            let stageDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-stage-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stageDir) }

            for url in sourceURLs {
                let target = stageDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: target)
            }

            process.arguments = ["-c", "-k", "--sequesterRsrc", stageDir.path, destinationZipURL.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "未知错误"
                throw ArchiveError.compressionFailed(errMsg)
            }
        }
    }

    /// Safely extracts a ZIP archive off the main thread after pre-scanning entries to block Zip-Slip and symlink escapes.
    public static func extractZip(at zipURL: URL, to destinationDir: URL) async throws -> [URL] {
        try Task.checkCancellation()
        return try await Task.detached {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: zipURL.path) else {
                throw ArchiveError.extractionFailed("Archive not found: \(zipURL.lastPathComponent)")
            }

            let entryNames = try listZipEntryNames(at: zipURL)
            try validateNoSymlinkEntries(at: zipURL)

            let standardizedDest = destinationDir.standardizedFileURL
            let destPrefix = standardizedDest.path.hasSuffix("/") ? standardizedDest.path : standardizedDest.path + "/"

            var topLevelOrder: [String] = []
            var seenTopLevel = Set<String>()

            for rawEntry in entryNames {
                try Task.checkCancellation()
                try validateZipEntryPath(rawEntry, destinationURL: standardizedDest, destinationPrefix: destPrefix)

                let trimmedSlashes = rawEntry.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let firstComponent = trimmedSlashes.split(separator: "/").first {
                    let top = String(firstComponent)
                    if !top.isEmpty && top != "__MACOSX" && seenTopLevel.insert(top).inserted {
                        topLevelOrder.append(top)
                    }
                }
            }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: standardizedDest, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, standardizedDest.path]
            let errPipe = Pipe()
            process.standardError = errPipe

            try runProcessWithCancellation(process)

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto exit \(process.terminationStatus)"
                throw ArchiveError.extractionFailed(errMsg)
            }

            let fm = FileManager.default
            return topLevelOrder.compactMap { name in
                let candidate = standardizedDest.appendingPathComponent(name)
                return fm.fileExists(atPath: candidate.path) ? candidate : nil
            }
        }.value
    }

    private static func listZipEntryNames(at zipURL: URL) throws -> [String] {
        let (status, stdout, stderr) = try runUnzip(arguments: ["-Z1", zipURL.path])
        guard status == 0 else {
            let detail = stderr.isEmpty ? "unzip -Z1 exit \(status)" : stderr
            throw ArchiveError.extractionFailed(detail)
        }
        return stdout
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    private static func validateNoSymlinkEntries(at zipURL: URL) throws {
        let (status, stdout, stderr) = try runUnzip(arguments: ["-Z", zipURL.path])
        guard status == 0 else {
            let detail = stderr.isEmpty ? "unzip -Z exit \(status)" : stderr
            throw ArchiveError.extractionFailed(detail)
        }
        for line in stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("Archive:") || trimmed.hasPrefix("Zip file size:") {
                continue
            }
            // In `unzip -Z` (ZipInfo), POSIX mode starts the entry line; symlinks begin with `l` followed by 9 mode chars.
            if let modeToken = trimmed.split(whereSeparator: { $0.isWhitespace }).first,
               modeToken.count == 10,
               modeToken.first == "l" {
                throw ArchiveError.unsafeArchive(trimmed)
            }
        }
    }

    private static func validateZipEntryPath(
        _ entry: String,
        destinationURL: URL,
        destinationPrefix: String
    ) throws {
        guard !entry.contains("\0"),
              !entry.hasPrefix("/"),
              !entry.hasPrefix("\\") else {
            throw ArchiveError.unsafeArchive(entry)
        }
        let normalizedSeparators = entry.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedSeparators.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains("..") {
            throw ArchiveError.unsafeArchive(entry)
        }
        let resolved = destinationURL.appendingPathComponent(normalizedSeparators).standardizedFileURL
        guard resolved.path == destinationURL.path || resolved.path.hasPrefix(destinationPrefix) else {
            throw ArchiveError.unsafeArchive(entry)
        }
    }

    private static func runUnzip(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try runProcessWithCancellation(process)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private static func runProcessWithCancellation(_ process: Process) throws {
        try Task.checkCancellation()
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
