import Foundation

public struct SyncNavigationManager: Sendable {
    public var localRoot: String
    public var remoteRoot: String
    public var isEnabled: Bool

    public init(localRoot: String, remoteRoot: String, isEnabled: Bool = false) {
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
        self.isEnabled = isEnabled
    }

    public mutating func updateRoots(localRoot: String, remoteRoot: String) {
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
    }

    public func remotePathForLocalNavigation(to newLocalPath: String) -> String? {
        guard isEnabled else { return nil }
        let normLocalRoot = (localRoot as NSString).standardizingPath
        let normNewLocal = (newLocalPath as NSString).standardizingPath

        guard normNewLocal.hasPrefix(normLocalRoot) else { return nil }
        var relative = String(normNewLocal.dropFirst(normLocalRoot.count))
        if relative.hasPrefix("/") { relative.removeFirst() }

        if relative.isEmpty {
            return remoteRoot
        }

        let normRemoteRoot = RemotePath.normalize(remoteRoot)
        if normRemoteRoot == "/" {
            return "/" + relative
        } else {
            return normRemoteRoot + "/" + relative
        }
    }

    public func localPathForRemoteNavigation(to newRemotePath: String) -> String? {
        guard isEnabled else { return nil }
        let normRemoteRoot = RemotePath.normalize(remoteRoot)
        let normNewRemote = RemotePath.normalize(newRemotePath)

        guard normNewRemote.hasPrefix(normRemoteRoot) else { return nil }
        var relative = String(normNewRemote.dropFirst(normRemoteRoot.count))
        if relative.hasPrefix("/") { relative.removeFirst() }

        let localURL = URL(fileURLWithPath: localRoot)
        if relative.isEmpty {
            return localURL.standardizedFileURL.path
        } else {
            return localURL.appendingPathComponent(relative).standardizedFileURL.path
        }
    }
}
