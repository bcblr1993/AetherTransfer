import Foundation
import Darwin

/// Watches both the file and its directory so atomic editor replacements remain observable.
/// No timer or network request runs while the draft is unchanged.
public final class FileEditWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.aethernative.AetherTransfer.edit-watcher", qos: .utility)
    private let file: URL
    private let changed: @Sendable () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var identity: String?
    private var stopped = false
    public init(file: URL, changed: @escaping @Sendable () -> Void) throws {
        self.file = file; self.changed = changed
        let descriptor = Darwin.open(file.deletingLastPathComponent().path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FileEditError.unsupportedText }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke], queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in self?.event(rebind: true) }
        directorySource = source
        bindFile(); source.resume()
    }
    private func bindFile() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        let descriptor = Darwin.open(file.path, O_EVTONLY | O_NOFOLLOW)
        var metadata = stat()
        guard descriptor >= 0 else { fileSource?.cancel(); fileSource = nil; identity = nil; return }
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { Darwin.close(descriptor); return }
        let id = "\(metadata.st_dev):\(metadata.st_ino)"
        guard id != identity else { Darwin.close(descriptor); return }
        fileSource?.cancel()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in self?.event(rebind: true) }
        fileSource = source; identity = id; source.resume()
    }
    private func event(rebind: Bool) {
        if rebind { bindFile() }
        lock.lock(); let active = !stopped; lock.unlock()
        if active { changed() }
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        directorySource?.cancel(); directorySource = nil
        fileSource?.cancel(); fileSource = nil
    }
    deinit { stop() }
}
