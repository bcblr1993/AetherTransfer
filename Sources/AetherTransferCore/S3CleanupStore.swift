import Foundation

/// Failed owned-upload aborts survive app restart; credentials and trust stay in the live connection.
public actor S3CleanupStore {
    public static let shared = S3CleanupStore()
    public let file: URL
    public init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherTransfer/s3-cleanup.json")
    }
    public func records() throws -> [S3MultipartCleanup] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1024 * 1024 else { throw S3Error.invalidMultipart }
        let records = try JSONDecoder().decode([S3MultipartCleanup].self, from: Data(contentsOf: file))
        try validate(records); return records
    }
    public func add(_ record: S3MultipartCleanup) throws {
        var values = try records()
        if !values.contains(where: { $0.id == record.id }) { values.append(record) }
        try write(values)
    }
    public func remove(_ record: S3MultipartCleanup) throws {
        try write(records().filter { $0.id != record.id })
    }
    private func validate(_ values: [S3MultipartCleanup]) throws {
        guard values.count <= 1000, Set(values.map(\.id)).count == values.count else { throw S3Error.invalidMultipart }
        for value in values {
            try value.endpoint.validate(); try S3Endpoint.validateKey(value.key)
            guard !value.key.isEmpty, !value.uploadID.isEmpty, value.uploadID.utf8.count <= 4096 else { throw S3Error.invalidMultipart }
        }
    }
    private func write(_ values: [S3MultipartCleanup]) throws {
        try validate(values)
        let data = try JSONEncoder().encode(values)
        guard data.count <= 1024 * 1024 else { throw S3Error.invalidMultipart }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
