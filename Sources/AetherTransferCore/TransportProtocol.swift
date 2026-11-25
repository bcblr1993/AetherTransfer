import Foundation

/// Extended metadata associated with a remote file or cloud object.
public struct RemoteObjectMetadata: Sendable, Equatable, Codable {
    public var contentType: String?
    public var cacheControl: String?
    public var storageClass: String?
    public var acl: String?
    public var customMetadata: [String: String]
    public var etag: String?
    public var size: Int64?
    public var modified: Date?

    public init(
        contentType: String? = nil,
        cacheControl: String? = nil,
        storageClass: String? = nil,
        acl: String? = nil,
        customMetadata: [String: String] = [:],
        etag: String? = nil,
        size: Int64? = nil,
        modified: Date? = nil
    ) {
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.storageClass = storageClass
        self.acl = acl
        self.customMetadata = customMetadata
        self.etag = etag
        self.size = size
        self.modified = modified
    }
}

/// Unified transport contract implemented by all protocol backends.
public protocol RemoteTransport: Sendable {
    func list(_ path: String) async throws -> [FileEntry]
    func download(
        _ remote: String,
        to destination: URL,
        overwrite: Bool,
        offset: Int64?,
        stagingURL: URL?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
    func upload(
        _ local: URL,
        to remote: String,
        overwrite: Bool,
        offset: Int64?,
        stagingRemotePath: String?,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws
    func mkdir(_ path: String) async throws
    func rename(_ source: String, to destination: String) async throws
    func remove(_ path: String, directory: Bool) async throws
    func chmod(_ path: String, permissions: POSIXPermissions) async throws
    func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata
    func updateMetadata(_ remotePath: String, metadata: RemoteObjectMetadata) async throws
    func presignedURL(for remotePath: String, expiresIn seconds: Int) async throws -> URL
}

public extension RemoteTransport {
    func download(_ remote: String, to destination: URL, overwrite: Bool = false) async throws {
        try await download(remote, to: destination, overwrite: overwrite, offset: nil, stagingURL: nil, progress: { _ in })
    }

    func upload(_ local: URL, to remote: String, overwrite: Bool = false) async throws {
        try await upload(local, to: remote, overwrite: overwrite, offset: nil, stagingRemotePath: nil, progress: { _ in })
    }

    func presignedURL(for remotePath: String) async throws -> URL {
        try await presignedURL(for: remotePath, expiresIn: 3600)
    }

    func chmod(_ path: String, permissions: POSIXPermissions) async throws {
        // No-op by default for object stores and HTTP transports without POSIX mode bits.
    }

    func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        throw TransferError.remote(L10n.tr("当前协议不支持读取扩展元数据。", "Extended metadata inspection is not supported by this protocol."))
    }

    func updateMetadata(_ remotePath: String, metadata: RemoteObjectMetadata) async throws {
        throw TransferError.remote(L10n.tr("当前协议不支持修改扩展元数据。", "Extended metadata editing is not supported by this protocol."))
    }

    func presignedURL(for remotePath: String, expiresIn seconds: Int) async throws -> URL {
        throw TransferError.remote(L10n.tr("当前协议不支持生成临时签名链接。", "Presigned URLs are not supported by this protocol."))
    }
}

/// Actor-based token-bucket throttler and bounded 64 KiB streaming helper for HTTP transports.
public actor StreamingThrottler {
    public static let defaultChunkSize: Int = 64 * 1024

    public let chunkSize: Int
    public let speedLimitBytesPerSec: Int64?

    private var availableTokens: Double
    private var lastRefillTime: ContinuousClock.Instant

    public init(speedLimitBytesPerSec: Int64? = nil, chunkSize: Int = StreamingThrottler.defaultChunkSize) {
        let validChunkSize = max(1024, chunkSize)
        self.chunkSize = validChunkSize
        if let limit = speedLimitBytesPerSec, limit > 0 {
            self.speedLimitBytesPerSec = limit
            self.availableTokens = Double(min(Int64(validChunkSize), limit))
        } else {
            self.speedLimitBytesPerSec = nil
            self.availableTokens = 0
        }
        self.lastRefillTime = ContinuousClock.now
    }

    /// Resets the token bucket state before starting a fresh transfer.
    public func reset() {
        lastRefillTime = ContinuousClock.now
        if let limit = speedLimitBytesPerSec {
            availableTokens = Double(min(Int64(chunkSize), limit))
        } else {
            availableTokens = 0
        }
    }

    /// Consumes tokens for `bytes`, suspending via cancellable `Task.sleep` when over budget.
    public func throttle(bytes: Int) async throws {
        try Task.checkCancellation()
        guard let limit = speedLimitBytesPerSec, limit > 0, bytes > 0 else { return }

        let now = ContinuousClock.now
        let elapsed = lastRefillTime.duration(to: now)
        let elapsedSeconds = max(0, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0)
        lastRefillTime = now

        let burstCapacity = max(Double(chunkSize), Double(limit))
        availableTokens = min(burstCapacity, availableTokens + elapsedSeconds * Double(limit))
        availableTokens -= Double(bytes)

        if availableTokens < 0 {
            let deficitSeconds = (-availableTokens) / Double(limit)
            let sleepNanos = UInt64(max(1.0, deficitSeconds * 1_000_000_000.0))
            try await Task.sleep(nanoseconds: sleepNanos)
            try Task.checkCancellation()
            availableTokens = 0
            lastRefillTime = ContinuousClock.now
        }
    }

    /// Streams a local file in bounded 64 KiB chunks off the main thread with cancellation and rate limiting.
    nonisolated public func streamFileChunks(
        at fileURL: URL,
        offset: Int64 = 0,
        length: Int64? = nil,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) -> ThrottledFileChunkSequence {
        let chunkLimit = self.chunkSize
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let worker = Task.detached {
                do {
                    try Task.checkCancellation()
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }

                    let fileSize = try Int64(handle.seekToEnd())
                    let startOffset = max(0, offset)
                    guard startOffset <= fileSize else {
                        throw TransferError.invalidPath
                    }
                    let remainingLimit = length.map { max(0, min($0, fileSize - startOffset)) } ?? (fileSize - startOffset)
                    let totalBytes = startOffset + remainingLimit

                    try handle.seek(toOffset: UInt64(startOffset))
                    var remaining = remainingLimit
                    var completed = startOffset

                    if let progress {
                        progress(TransferProgress(completed: completed, total: totalBytes))
                    }

                    while remaining > 0 {
                        try Task.checkCancellation()
                        let readCount = Int(min(Int64(chunkLimit), remaining))
                        guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
                            break
                        }
                        try await self.throttle(bytes: chunk.count)
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                        remaining -= Int64(chunk.count)
                        completed += Int64(chunk.count)
                        if let progress {
                            progress(TransferProgress(completed: completed, total: totalBytes))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
        return ThrottledFileChunkSequence(stream: stream)
    }

    /// Writes an async byte sequence to disk in bounded 64 KiB chunks with cancellation and rate limiting.
    nonisolated public func writeAsyncBytes<S: AsyncSequence>(
        _ bytes: S,
        to destination: URL,
        expectedTotal: Int64 = -1,
        appendOffset: Int64 = 0,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws -> Int64 where S.Element == UInt8 {
        try Task.checkCancellation()
        let chunkLimit = self.chunkSize
        let startOffset = max(0, appendOffset)
        let handle: FileHandle = try await ResumeIO.run {
            let fm = FileManager.default
            if startOffset > 0 && fm.fileExists(atPath: destination.path) {
                let h = try FileHandle(forUpdating: destination)
                try h.truncate(atOffset: UInt64(startOffset))
                try h.seekToEnd()
                return h
            }
            fm.createFile(atPath: destination.path, contents: nil)
            return try FileHandle(forWritingTo: destination)
        }
        defer { try? handle.close() }

        var buffer: [UInt8] = []
        buffer.reserveCapacity(chunkLimit)
        var writtenTotal = startOffset

        if let progress {
            progress(TransferProgress(completed: writtenTotal, total: expectedTotal))
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= chunkLimit {
                let chunkData = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                try await self.throttle(bytes: chunkData.count)
                try await ResumeIO.run {
                    try handle.write(contentsOf: chunkData)
                }
                writtenTotal += Int64(chunkData.count)
                if let progress {
                    progress(TransferProgress(completed: writtenTotal, total: expectedTotal))
                }
            }
        }

        try Task.checkCancellation()

        if !buffer.isEmpty {
            try Task.checkCancellation()
            let chunkData = Data(buffer)
            buffer.removeAll()
            try await self.throttle(bytes: chunkData.count)
            try await ResumeIO.run {
                try handle.write(contentsOf: chunkData)
            }
            writtenTotal += Int64(chunkData.count)
            if let progress {
                progress(TransferProgress(completed: writtenTotal, total: expectedTotal))
            }
        }

        return writtenTotal
    }

    /// Creates a bounded 64 KiB `InputStream` backed by `streamFileChunks` for streamed HTTP uploads.
    nonisolated public func pipeFileToBoundStream(
        at fileURL: URL,
        offset: Int64 = 0,
        length: Int64? = nil,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) throws -> (inputStream: InputStream, transferTask: Task<Void, Error>) {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: chunkSize, inputStream: &input, outputStream: &output)
        guard let inputStream = input, let outputStream = output else {
            throw TransferError.remote(L10n.tr("无法创建流式上传管道。", "Unable to create streaming upload pipe."))
        }
        outputStream.open()

        let box = SendableOutputStream(stream: outputStream)
        let throttler = self
        let task = Task.detached {
            let out = box.stream
            defer { out.close() }
            let chunks = throttler.streamFileChunks(at: fileURL, offset: offset, length: length, progress: progress)
            for try await chunk in chunks {
                try Task.checkCancellation()
                var written = 0
                while written < chunk.count {
                    try Task.checkCancellation()
                    if out.streamStatus == .closed || out.streamStatus == .atEnd {
                        return
                    }
                    if out.streamStatus == .error {
                        throw out.streamError ?? TransferError.remote(L10n.tr("上传流写入失败。", "Upload stream write failed."))
                    }
                    if !out.hasSpaceAvailable {
                        try await Task.sleep(nanoseconds: 2_000_000)
                        continue
                    }
                    let n: Int = try chunk.withUnsafeBytes { rawBuffer in
                        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        let count = out.write(base.advanced(by: written), maxLength: chunk.count - written)
                        if count < 0 {
                            throw out.streamError ?? TransferError.remote(L10n.tr("上传流写入失败。", "Upload stream write failed."))
                        }
                        return count
                    }
                    if n == 0 {
                        try await Task.sleep(nanoseconds: 2_000_000)
                    } else {
                        written += n
                    }
                }
            }
        }
        return (inputStream, task)
    }
}

private struct SendableOutputStream: @unchecked Sendable {
    let stream: OutputStream
}

/// Async sequence wrapper that ensures task cancellation always raises `CancellationError` rather than returning EOF.
public struct ThrottledFileChunkSequence: AsyncSequence, Sendable {
    public typealias Element = Data
    private let stream: AsyncThrowingStream<Data, Error>

    init(stream: AsyncThrowingStream<Data, Error>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

        init(iterator: AsyncThrowingStream<Data, Error>.AsyncIterator) {
            self.iterator = iterator
        }

        public mutating func next() async throws -> Data? {
            try Task.checkCancellation()
            let chunk = try await iterator.next()
            try Task.checkCancellation()
            return chunk
        }
    }
}
