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

    // Order is significant: URL userinfo and query parameters run before generic header/kv rules.
    private static let rules: [Rule] = [
        // 1. URL userinfo: scheme://user:secret@host -> scheme://user:***@host
        Rule(
            #"([A-Za-z][A-Za-z0-9+.-]*://[^/\s:@?#"']*:)[^/\s@?#"']*(@)"#,
            replacement: "$1***$2"
        ),
        // 2. Sensitive URL query parameters (preserves trailing &other=... params)
        Rule(
            #"((?:^|[?&;\s,(])(?:X-Amz-Signature|X-Amz-Security-Token|sig|token|password|passphrase|access_token|client_secret|sas_token)\s*=)[^&\s#"'>)]+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        // 3. Authorization headers (Basic, Bearer, AWS4-HMAC-SHA256, SharedKey, etc.)
        Rule(
            #"(Authorization["']?\s*:\s*["']?(?:(?:AWS4-HMAC-SHA256|Basic|Bearer|SharedKey|Token|Digest|Negotiate)\s+)?)[^\r\n"']+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        // 4. Sensitive cloud/auth HTTP headers
        Rule(
            #"((?:X-Amz-Security-Token|X-Amz-Signature|X-Auth-Token|X-Auth-Key)["']?\s*:\s*["']?)[^\r\n"']+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        // 5a. FTP/SFTP PASS lines at line or trace prompt start (case-insensitive)
        Rule(
            #"^(\s*(?:(?:>|C:|FTP|SFTP|CMD|\[[^\]]+\])\s*:?\s*)?PASS[ \t]+)[^\r\n]+"#,
            options: [.caseInsensitive, .anchorsMatchLines],
            replacement: "$1[REDACTED]"
        ),
        // 5b. Inline uppercase FTP PASS command
        Rule(
            #"(\bPASS[ \t]+)[^\r\n]+"#,
            replacement: "$1[REDACTED]"
        ),
        // 6. Private key passphrases & password key/value lines
        Rule(
            #"((?:private[\s_-]*key[\s_-]*)?passphrase(?:\s+for\s+[^\r\n:]+)?["']?\s*[:=]\s*["']?)[^\r\n"']+"#,
            options: [.caseInsensitive],
            replacement: "$1[REDACTED]"
        ),
        Rule(
            #"(password["']?\s*:\s*["']?)[^\r\n"']+"#,
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
