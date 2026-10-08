import Foundation
import Darwin

/// Same-directory staging is committed in one filesystem rename; no Foundation exchange/cleanup sequence.
enum LocalFileCommit {
    static func commit(_ staging: URL, to destination: URL, overwrite: Bool) async throws {
        let task = Task.detached { try commitSync(staging, to: destination, overwrite: overwrite) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func commitSync(_ staging: URL, to destination: URL, overwrite: Bool) throws {
        guard staging.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL ||
              staging.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw TransferError.remote(L10n.text("暂存文件必须位于目标目录或其专属子目录。"))
        }
        var target = stat()
        let exists = destination.path.withCString { lstat($0, &target) }
        if exists == 0 {
            guard overwrite else { throw TransferError.conflict(destination.lastPathComponent) }
            guard target.st_mode & S_IFMT == S_IFREG else { throw TransferError.conflict(destination.lastPathComponent) }
            guard staging.path.withCString({ chmod($0, target.st_mode & 0o7777) }) == 0 else { throw posixError() }
        } else if errno != ENOENT {
            throw posixError()
        }
        try Task.checkCancellation()
        let result = staging.path.withCString { from in
            destination.path.withCString { to in renamex_np(from, to, overwrite ? 0 : UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST { throw TransferError.conflict(destination.lastPathComponent) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
