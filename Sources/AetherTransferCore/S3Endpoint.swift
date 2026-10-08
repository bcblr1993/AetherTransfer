import Foundation

/// Non-secret, bucket-scoped path-style endpoint. No file-path normalization is applied to object keys.
public struct S3Endpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var bucket: String
    public var region: String
    public var secure: Bool
    public init(host: String, port: Int = 443, bucket: String, region: String = "us-east-1", secure: Bool = true) {
        self.host = host; self.port = port; self.bucket = bucket; self.region = region; self.secure = secure
    }
    public func validate() throws {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains(where: { "/@?#".contains($0) }),
              (1...65535).contains(port), (3...63).contains(bucket.utf8.count),
              bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              bucket.first != ".", bucket.last != ".", bucket.first != "-", bucket.last != "-", !bucket.contains(".."),
              (1...63).contains(region.utf8.count),
              region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              secure || ["127.0.0.1", "localhost", "::1"].contains(host) else { throw TransferError.invalidConnection }
    }
    public static func validateKey(_ key: String) throws {
        guard key.utf8.count <= 1024, !key.utf8.contains(0) else { throw TransferError.invalidPath }
    }
    public func url(key: String = "", query: [(String, String)] = []) throws -> String {
        try validate(); try Self.validateKey(key)
        var authority = URLComponents(); authority.scheme = secure ? "https" : "http"
        authority.host = host; authority.port = port
        guard let base = authority.url?.absoluteString else { throw TransferError.invalidConnection }
        let encoded: [(String, String)] = query.map { pair in (Self.encode(pair.0), Self.encode(pair.1)) }
        let parameters = encoded.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        let path = base + "/" + bucket + "/" + Self.encode(key, slash: true)
        let queryString = parameters.map { pair in pair.0 + "=" + pair.1 }.joined(separator: "&")
        return path + (queryString.isEmpty ? "" : "?" + queryString)
    }
    static func encode(_ value: String, slash: Bool = false) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) || (slash && byte == 47) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

/// Secrets stay outside Codable profiles and recovery records.
public struct S3Credentials: Sendable {
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String
    public init(accessKey: String, secretKey: String, sessionToken: String = "") {
        self.accessKey = accessKey; self.secretKey = secretKey; self.sessionToken = sessionToken
    }
    public func validate() throws {
        guard !accessKey.isEmpty, !secretKey.isEmpty, accessKey.utf8.count <= 256, secretKey.utf8.count <= 4096,
              sessionToken.utf8.count <= 16 * 1024,
              [accessKey, secretKey, sessionToken].allSatisfy({ $0.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e } }) else {
            throw TransferError.invalidConnection
        }
    }
}

public struct S3Object: Identifiable, Hashable, Sendable {
    // Swift String equality folds Unicode normalization; S3 key identity is byte-exact.
    public var id: String { S3Endpoint.encode(key) }
    public let key: String
    public let name: String
    public let isPrefix: Bool
    public let size: Int64
    public let modified: Date?
    public let etag: String?
    public static func == (a: S3Object, b: S3Object) -> Bool {
        a.key.utf8.elementsEqual(b.key.utf8) && a.isPrefix == b.isPrefix && a.size == b.size && a.modified == b.modified && a.etag == b.etag
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(isPrefix); hasher.combine(size); hasher.combine(modified); hasher.combine(etag)
    }
}
