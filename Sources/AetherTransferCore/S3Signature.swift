import Foundation
import CryptoKit

/// S3 SigV4 over the already encoded, sorted URL. Object paths are never normalized.
/// Spec and public test vectors: https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html
enum S3Signature {
    static func headers(method: String, url: String, region: String, credentials: S3Credentials,
                        headers: [String] = [], body: String? = nil, now: Date = Date()) throws -> [String] {
        try credentials.validate()
        guard (1...63).contains(region.utf8.count), region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              ["GET", "HEAD", "PUT", "POST", "DELETE"].contains(method), let parts = URLComponents(string: url),
              let hostname = parts.host, parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw TransferError.invalidConnection
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now), day = String(timestamp.prefix(8))
        var values: [String: String] = [:]
        for header in headers {
            guard let colon = header.firstIndex(of: ":") else { throw TransferError.invalidConnection }
            let name = header[..<colon].lowercased(), value = String(header[header.index(after: colon)...])
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 <= 126) }), values[name] == nil,
                  !["authorization", "host", "x-amz-date", "x-amz-security-token"].contains(name) else {
                throw TransferError.invalidConnection
            }
            values[name] = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            guard values[name]?.isEmpty == false else { throw TransferError.invalidConnection }
        }
        var host = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        if let port = parts.port, port != (parts.scheme == "https" ? 443 : 80) { host += ":\(port)" }
        values["host"] = host; values["x-amz-date"] = timestamp
        if !credentials.sessionToken.isEmpty { values["x-amz-security-token"] = credentials.sessionToken }
        let payload = values["x-amz-content-sha256"] ?? hex(SHA256.hash(data: Data((body ?? "").utf8)))
        guard payload.utf8.count == 64, payload.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TransferError.invalidConnection
        }
        values["x-amz-content-sha256"] = payload
        let names = values.keys.sorted(), signed = names.joined(separator: ";")
        let canonicalHeaders = names.map { $0 + ":" + values[$0]! + "\n" }.joined()
        let canonicalPath = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let canonical = [method, canonicalPath, parts.percentEncodedQuery ?? "", canonicalHeaders, signed, payload].joined(separator: "\n")
        let scope = day + "/" + region + "/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        let dateKey = hmac(Data(("AWS4" + credentials.secretKey).utf8), day)
        let regionKey = hmac(dateKey, region), serviceKey = hmac(regionKey, "s3"), signingKey = hmac(serviceKey, "aws4_request")
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope),SignedHeaders=\(signed),Signature=\(hex(hmac(signingKey, stringToSign)))"
        return names.map { $0 + ": " + values[$0]! } + ["Authorization: " + authorization]
    }
    private static func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
