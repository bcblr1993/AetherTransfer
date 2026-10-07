import Foundation
import AetherTransferCore

struct Result: Codable {
    let scenario: String
    let items: Int
    let medianMilliseconds: Double
    let maximumMilliseconds: Double
}

func measure(_ scenario: String, items: Int, operation: () throws -> Void) rethrows -> Result {
    var values: [Double] = []
    for _ in 0..<5 {
        let start = ContinuousClock.now
        try operation()
        let duration = start.duration(to: .now).components
        values.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
    }
    values.sort()
    return Result(scenario: scenario, items: items, medianMilliseconds: values[2], maximumMilliseconds: values[4])
}

let count = 10_000
let listing = (0..<count).map { "-rw-r--r-- 1 owner group \($0) Oct 7 10:30 中文 file \($0).txt" }.joined(separator: "\n")
let entries = try DirectoryListing.parse(listing, parent: "/data")
var results = [try measure("Remote LIST parse with Unicode and dates", items: count) {
    let parsed = try DirectoryListing.parse(listing, parent: "/data")
    guard parsed.count == count else { fatalError("Incomplete parse") }
}]
let davItems = (0..<count).map { index in
    "<d:response><d:href>/data/file%20\(index).txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>\(index)</d:getcontentlength><d:getlastmodified>Wed, 07 Oct 2026 10:30:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
}.joined()
let davListing = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/data/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" + davItems + "</d:multistatus>"
results.append(try measure("WebDAV XML parse with dates and direct-child validation", items: count) {
    let parsed = try WebDAVListing.parse(davListing, parent: "/data", origin: "https://example.test/data/")
    precondition(parsed.count == count && parsed.last?.size == 9999 && parsed.first?.modified != nil)
})
results.append(measure("Natural name sort", items: count) {
    let sorted = FilePresentation.entries(entries.reversed(), query: "", showHidden: true)
    precondition(sorted.count == count && sorted.first?.name == "中文 file 0.txt")
})
results.append(measure("Filter and size sort", items: count) {
    let filtered = FilePresentation.entries(entries, query: "file 99", showHidden: true, field: .size, descending: true)
    precondition(!filtered.isEmpty)
})
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-benchmark-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
for index in 0..<5000 { try Data().write(to: folder.appendingPathComponent("file \(index).txt")) }
results.append(try measure("Local directory metadata and natural sort", items: 5000) {
    let files = try LocalFiles.list(folder)
    precondition(files.count == 5000)
})
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(results), as: UTF8.self))
