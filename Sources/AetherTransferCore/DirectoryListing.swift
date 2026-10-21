import Foundation

public enum DirectoryListing {
    public static func parse(_ text: String, parent: String) throws -> [FileEntry] {
        let pattern = #"^([dl-][rwxstST-]{9}[+@.]?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+([A-Za-z]{3}|\d{1,2})\s+(\d{1,2}|[A-Za-z]{3})\s+(\d{4}|\d{1,2}:\d{2})\s+(.+)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var entries: [FileEntry] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty || line.hasPrefix("total ") { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { throw TransferError.invalidListing(String(line.prefix(100))) }
            func value(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
            let mode = value(1)
            let link = mode.hasPrefix("l")
            var name = value(6)
            if link, let arrow = name.range(of: " -> ", options: .backwards) { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            let path = try RemotePath.join(parent, name)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            let time = value(5)
            formatter.dateFormat = time.contains(":") ? "MMM d yyyy HH:mm" : "MMM d yyyy"
            let year = Calendar.current.component(.year, from: Date())
            let dayFirst = Int(value(3)) != nil
            let month = dayFirst ? value(4) : value(3)
            let day = dayFirst ? value(3) : value(4)
            var date = formatter.date(from: "\(month) \(day) \(time.contains(":") ? "\(year) \(time)" : time)")
            if let candidate = date, time.contains(":"), candidate.timeIntervalSinceNow > 86400 {
                date = Calendar.current.date(byAdding: .year, value: -1, to: candidate)
            }
            entries.append(FileEntry(name: name, path: path, isDirectory: mode.hasPrefix("d"),
                                     isSymbolicLink: link, size: Int64(value(2)) ?? 0, modified: date, permissions: mode))
        }
        return FileEntry.sorted(entries)
    }
}

public struct LocalFileItem: Sendable {
    public let relativePath: String
    public let fileURL: URL
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?
    public init(relativePath: String, fileURL: URL, isDirectory: Bool, size: Int64, modified: Date? = nil) {
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

public enum LocalFiles {
    public static func list(_ url: URL, showHidden: Bool = false) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return FileEntry.sorted(try urls.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: values.isDirectory == true,
                             isSymbolicLink: values.isSymbolicLink == true, size: Int64(values.fileSize ?? 0),
                             modified: values.contentModificationDate)
        })
    }
    public static func walk(_ rootURL: URL, showHidden: Bool = false) throws -> [LocalFileItem] {
        var results: [LocalFileItem] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let rootPath = rootURL.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            let isDir = values.isDirectory == true
            let standardPath = fileURL.standardizedFileURL.path
            guard standardPath.hasPrefix(rootPath) else { continue }
            var relative = String(standardPath.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate
            results.append(LocalFileItem(relativePath: relative, fileURL: fileURL, isDirectory: isDir, size: size, modified: modified))
        }
        return results
    }
}
