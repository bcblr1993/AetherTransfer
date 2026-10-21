import Foundation

public enum ArchiveError: Error, LocalizedError, Sendable {
    case compressionFailed(String)
    case emptySource

    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let msg): "压缩文件失败：\(msg)"
        case .emptySource: "未指定需要压缩的文件。"
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
}
