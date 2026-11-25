import Foundation

// MARK: - Protocol Transcript Models

public enum TranscriptCategory: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case connect
    case command
    case response
    case transfer
    case sync
    case error

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .connect: return L10n.tr("连接", "Connect")
        case .command: return L10n.tr("命令", "Command")
        case .response: return L10n.tr("响应", "Response")
        case .transfer: return L10n.tr("传输", "Transfer")
        case .sync: return L10n.tr("同步", "Sync")
        case .error: return L10n.tr("错误", "Error")
        }
    }

    public var symbolName: String {
        switch self {
        case .connect: return "network"
        case .command: return "chevron.right.square"
        case .response: return "arrow.turn.down.left"
        case .transfer: return "arrow.up.arrow.down.circle"
        case .sync: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

public struct TranscriptEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let connectionName: String
    public let protocolTitle: String
    public let category: TranscriptCategory
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        connectionName: String,
        protocolTitle: String,
        category: TranscriptCategory,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.connectionName = connectionName
        self.protocolTitle = protocolTitle
        self.category = category
        self.message = message
    }
}

// MARK: - Strict Transcript Redactor

public enum TranscriptRedactor {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let replacement: String

        init(_ pattern: String, options: NSRegularExpression.Options = [], replacement: String) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.replacement = replacement
        }
    }

    // Order is significant: URL userinfo and query/kv parameters run before header/line rules.
    // Whitespace inside header/kv matchers uses [ \t] (never \s) so patterns never bleed across newlines.
    private static let rules: [Rule] = [
        // 1. URL userinfo: scheme://user:secret@host -> scheme://user:***@host
        Rule(
            #"([A-Za-z][A-Za-z0-9+.-]*://[^/\s:@?#"']*:)[^/\s@?#"']*(@)"#,
            replacement: "$1***$2"
        ),
        // 2a. Quoted sensitive key=value parameters (e.g. password="...", token='...', X-Auth-Token="...")
        Rule(
            #"((?:^|[?&;\s,("'])(?:X-Amz-Signature|X-Amz-Security-Token|X-Auth-Token|X-Auth-Key|sig|token|password|passphrase|access_token|client_secret|sas_token)[ \t]*=[ \t]*")[^"\r\n]+(")"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"((?:^|[?&;\s,("'])(?:X-Amz-Signature|X-Amz-Security-Token|X-Auth-Token|X-Auth-Key|sig|token|password|passphrase|access_token|client_secret|sas_token)[ \t]*=[ \t]*')[^'\r\n]+(')"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        // 2b. Unquoted URL query / key=value parameters (preserves trailing &other=... params and closing quotes)
        Rule(
            #"((?:^|[?&;\s,("'])(?:X-Amz-Signature|X-Amz-Security-Token|X-Auth-Token|X-Auth-Key|sig|token|password|passphrase|access_token|client_secret|sas_token)[ \t]*=[ \t]*)[^&\s#"'>)]+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        // 3a. Quoted Authorization headers (JSON {"Authorization": "..."} or curl -H "..." / -H '...')
        Rule(
            #"("Authorization"[ \t]*:[ \t]*"(?:(?:AWS4-HMAC-SHA256|Basic|Bearer|SharedKey|Token|Digest|Negotiate)[ \t]+)?)[^"\r\n]+(")"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"('Authorization'[ \t]*:[ \t]*'(?:(?:AWS4-HMAC-SHA256|Basic|Bearer|SharedKey|Token|Digest|Negotiate)[ \t]+)?)[^'\r\n]+(')"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"("Authorization[ \t]*:[ \t]*(?:(?:AWS4-HMAC-SHA256|Basic|Bearer|SharedKey|Token|Digest|Negotiate)[ \t]+)?)[^"\r\n]+(")"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"('Authorization[ \t]*:[ \t]*(?:(?:AWS4-HMAC-SHA256|Basic|Bearer|SharedKey|Token|Digest|Negotiate)[ \t]+)?)[^'\r\n]+(')"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        // 3b. Unquoted HTTP Authorization headers (handles Digest with internal quotes to EOL without bleeding across newlines)
        Rule(
            #"((?:^|(?<=[^"'\w]))Authorization[ \t]*:[ \t]*(?:(?:AWS4-HMAC-SHA256|Basic|Bearer|SharedKey|Token|Digest|Negotiate)[ \t]+)?)[^\r\n]+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        // 4a. Quoted cloud/auth HTTP headers
        Rule(
            #"("(?:X-Amz-Security-Token|X-Amz-Signature|X-Auth-Token|X-Auth-Key)"[ \t]*:[ \t]*")[^"\r\n]+(")"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"('(?:X-Amz-Security-Token|X-Amz-Signature|X-Auth-Token|X-Auth-Key)'[ \t]*:[ \t]*')[^'\r\n]+(')"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"("(?:X-Amz-Security-Token|X-Amz-Signature|X-Auth-Token|X-Auth-Key)[ \t]*:[ \t]*)[^"\r\n]+(")"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"('(?:X-Amz-Security-Token|X-Amz-Signature|X-Auth-Token|X-Auth-Key)[ \t]*:[ \t]*)[^'\r\n]+(')"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        // 4b. Unquoted cloud/auth HTTP headers
        Rule(
            #"((?:^|(?<=[^"'\w]))(?:X-Amz-Security-Token|X-Amz-Signature|X-Auth-Token|X-Auth-Key)[ \t]*:[ \t]*)[^\r\n]+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        // 5a. FTP/SFTP PASS lines at line or trace prompt start (case-insensitive)
        Rule(
            #"^([ \t]*(?:(?:>|C:|FTP|SFTP|CMD|\[[^\]]+\])[ \t]*:?[ \t]*)?PASS[ \t]+)[^\r\n]+"#,
            options: [.caseInsensitive, .anchorsMatchLines],
            replacement: "$1[REDACTED]"
        ),
        // 5b. Inline uppercase FTP PASS command
        Rule(
            #"(\bPASS[ \t]+)[^\r\n]+"#,
            replacement: "$1[REDACTED]"
        ),
        // 6a. Quoted passphrase / password JSON/kv fields
        Rule(
            #"("(?:(?:private[ \t_-]*key[ \t_-]*)?passphrase|password)"[ \t]*:[ \t]*")[^"\r\n]+(")"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        Rule(
            #"('(?:(?:private[ \t_-]*key[ \t_-]*)?passphrase|password)'[ \t]*:[ \t]*')[^'\r\n]+(')"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]$2"
        ),
        // 6b. Unquoted private key passphrases & password colon lines
        Rule(
            #"((?:^|(?<=[^"'\w]))(?:(?:private[ \t_-]*key[ \t_-]*)?passphrase(?:[ \t]+for[ \t]+[^\r\n:]+)?|password)[ \t]*:[ \t]*)[^\r\n]+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        )
    ]

    public static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var output = raw
        for rule in rules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = rule.regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: rule.replacement)
        }
        return output
    }
}

// MARK: - Thread-Safe Bounded Transcript Logger

public final class TranscriptLogger: @unchecked Sendable {
    public let maxEntries: Int
    private let lock = NSLock()
    private var buffer: [TranscriptEntry] = []
    public var onEntriesUpdated: (@Sendable () -> Void)?

    public init(maxEntries: Int = 1000) {
        self.maxEntries = max(1, maxEntries)
    }

    @discardableResult
    public func append(
        connectionName: String = "",
        protocolTitle: String = "",
        category: TranscriptCategory,
        message: String,
        timestamp: Date = Date()
    ) -> TranscriptEntry {
        let entry = TranscriptEntry(
            timestamp: timestamp,
            connectionName: TranscriptRedactor.sanitize(connectionName),
            protocolTitle: protocolTitle,
            category: category,
            message: TranscriptRedactor.sanitize(message)
        )
        lock.lock()
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        let callback = onEntriesUpdated
        lock.unlock()
        callback?()
        return entry
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    public func entries(category: TranscriptCategory? = nil, search: String = "") -> [TranscriptEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let snapshot = buffer
        lock.unlock()

        return snapshot.filter { entry in
            if let category, entry.category != category {
                return false
            }
            if !query.isEmpty {
                let matchesMessage = entry.message.localizedCaseInsensitiveContains(query)
                let matchesConn = entry.connectionName.localizedCaseInsensitiveContains(query)
                let matchesProto = entry.protocolTitle.localizedCaseInsensitiveContains(query)
                return matchesMessage || matchesConn || matchesProto
            }
            return true
        }
    }

    public func exportText(category: TranscriptCategory? = nil, search: String = "") -> String {
        let filtered = entries(category: category, search: search)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return filtered.map { entry in
            let ts = formatter.string(from: entry.timestamp)
            let conn = entry.connectionName.isEmpty ? "-" : entry.connectionName
            let proto = entry.protocolTitle.isEmpty ? "-" : entry.protocolTitle
            return "[\(ts)] [\(conn) · \(proto)] [\(entry.category.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        let callback = onEntriesUpdated
        lock.unlock()
        callback?()
    }
}
