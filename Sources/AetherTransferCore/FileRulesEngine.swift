import Foundation

// MARK: - Transmit 5 File Rules & ASCII Transfer Types

public enum RuleField: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case name
    case fileExtension
    case path
    case sizeBytes
    case modifiedDate

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .name: return L10n.tr("文件名", "Name")
        case .fileExtension: return L10n.tr("扩展名", "Extension")
        case .path: return L10n.tr("路径", "Path")
        case .sizeBytes: return L10n.tr("大小 (字节)", "Size (Bytes)")
        case .modifiedDate: return L10n.tr("修改日期", "Date Modified")
        }
    }
}

public enum RuleOperator: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case `is`
    case isNot
    case contains
    case beginsWith
    case endsWith
    case matchesGlob
    case greaterThan
    case lessThan

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .is: return L10n.tr("等于", "is")
        case .isNot: return L10n.tr("不等于", "is not")
        case .contains: return L10n.tr("包含", "contains")
        case .beginsWith: return L10n.tr("开头为", "begins with")
        case .endsWith: return L10n.tr("结尾为", "ends with")
        case .matchesGlob: return L10n.tr("匹配通配符 (Glob)", "matches glob")
        case .greaterThan: return L10n.tr("大于 / 晚于", "greater than")
        case .lessThan: return L10n.tr("小于 / 早于", "less than")
        }
    }
}

public enum RuleMatchMode: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case all
    case any
    case none

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .all: return L10n.tr("满足所有条件", "All of the following")
        case .any: return L10n.tr("满足任一条件", "Any of the following")
        case .none: return L10n.tr("不满足以下任何条件", "None of the following")
        }
    }
}

public enum RuleScope: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case transfersAndSync
    case browserAndSync
    case all

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .transfersAndSync: return L10n.tr("传输与同步", "Transfers & Sync")
        case .browserAndSync: return L10n.tr("文件浏览器与同步", "Browser & Sync")
        case .all: return L10n.tr("全部范围", "All")
        }
    }

    public var appliesToSync: Bool { true }

    public var appliesToTransfers: Bool {
        self == .transfersAndSync || self == .all
    }

    public var appliesToBrowser: Bool {
        self == .browserAndSync || self == .all
    }

    public func applies(to targetScope: RuleScope) -> Bool {
        if self == .all || targetScope == .all { return true }
        return self == targetScope
    }
}

public struct RulePredicate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var field: RuleField
    public var op: RuleOperator
    public var value: String
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        field: RuleField,
        op: RuleOperator,
        value: String,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
    }

    enum CodingKeys: String, CodingKey {
        case id, field, op, value, caseSensitive
        case legacyOperator = "operator"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        field = try container.decode(RuleField.self, forKey: .field)
        if let decodedOp = try container.decodeIfPresent(RuleOperator.self, forKey: .op) {
            op = decodedOp
        } else {
            op = try container.decode(RuleOperator.self, forKey: .legacyOperator)
        }
        value = try container.decode(String.self, forKey: .value)
        caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(field, forKey: .field)
        try container.encode(op, forKey: .op)
        try container.encode(value, forKey: .value)
        try container.encode(caseSensitive, forKey: .caseSensitive)
    }

    public func matches(
        name: String,
        relativePath: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        modified: Date? = nil,
        referenceDate: Date = Date()
    ) -> Bool {
        switch field {
        case .name:
            return Self.compareString(candidate: name, pattern: value, op: op, caseSensitive: caseSensitive)

        case .fileExtension:
            // Directories do not carry file extensions; avoid false positives on `.isNot`.
            guard !isDirectory else { return false }
            let ext = Self.extractExtension(from: name)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTarget = (trimmed.hasPrefix(".") && trimmed.count > 1) ? String(trimmed.dropFirst()) : trimmed
            return Self.compareString(candidate: ext, pattern: normalizedTarget, op: op, caseSensitive: caseSensitive)

        case .path:
            let normalizedCandidate: String = {
                if value.hasPrefix("/") {
                    return relativePath.hasPrefix("/") ? relativePath : "/" + relativePath
                }
                return relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
            }()
            return Self.compareString(candidate: normalizedCandidate, pattern: value, op: op, caseSensitive: caseSensitive)

        case .sizeBytes:
            guard !isDirectory, let threshold = Self.parseByteSize(value) else { return false }
            switch op {
            case .is: return size == threshold
            case .isNot: return size != threshold
            case .greaterThan: return size > threshold
            case .lessThan: return size < threshold
            case .contains, .beginsWith, .endsWith, .matchesGlob:
                return Self.compareString(candidate: String(size), pattern: value, op: op, caseSensitive: false)
            }

        case .modifiedDate:
            guard let modified, let parsed = Self.parseTargetDate(value, referenceDate: referenceDate) else {
                return false
            }
            switch op {
            case .greaterThan:
                return modified > parsed.date
            case .lessThan:
                return modified < parsed.date
            case .is:
                if parsed.hasTimeComponent {
                    return abs(modified.timeIntervalSince(parsed.date)) < 1.0
                }
                return Calendar.current.isDate(modified, inSameDayAs: parsed.date)
            case .isNot:
                if parsed.hasTimeComponent {
                    return abs(modified.timeIntervalSince(parsed.date)) >= 1.0
                }
                return !Calendar.current.isDate(modified, inSameDayAs: parsed.date)
            case .contains, .beginsWith, .endsWith, .matchesGlob:
                return false
            }
        }
    }

    var dependsOnlyOnNameOrPath: Bool {
        field == .name || field == .path
    }

    private static func extractExtension(from name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private static func compareString(candidate: String, pattern: String, op: RuleOperator, caseSensitive: Bool) -> Bool {
        let lhs = caseSensitive ? candidate : candidate.lowercased()
        let rhs = caseSensitive ? pattern : pattern.lowercased()
        switch op {
        case .is:
            return lhs == rhs
        case .isNot:
            return lhs != rhs
        case .contains:
            guard !rhs.isEmpty else { return false }
            return lhs.contains(rhs)
        case .beginsWith:
            guard !rhs.isEmpty else { return false }
            return lhs.hasPrefix(rhs)
        case .endsWith:
            guard !rhs.isEmpty else { return false }
            return lhs.hasSuffix(rhs)
        case .matchesGlob:
            guard !rhs.isEmpty else { return false }
            return fnmatch(rhs, lhs, 0) == 0
        case .greaterThan:
            return lhs.localizedStandardCompare(rhs) == .orderedDescending
        case .lessThan:
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    public static func parseByteSize(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = Int64(trimmed) {
            return exact
        }
        let lower = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        let suffixes: [(String, Double)] = [
            ("tib", 1024.0 * 1024.0 * 1024.0 * 1024.0),
            ("tb", 1024.0 * 1024.0 * 1024.0 * 1024.0),
            ("t", 1024.0 * 1024.0 * 1024.0 * 1024.0),
            ("gib", 1024.0 * 1024.0 * 1024.0),
            ("gb", 1024.0 * 1024.0 * 1024.0),
            ("g", 1024.0 * 1024.0 * 1024.0),
            ("mib", 1024.0 * 1024.0),
            ("mb", 1024.0 * 1024.0),
            ("m", 1024.0 * 1024.0),
            ("kib", 1024.0),
            ("kb", 1024.0),
            ("k", 1024.0),
            ("b", 1.0)
        ]
        for (suffix, multiplier) in suffixes where lower.hasSuffix(suffix) {
            let numStr = String(lower.dropLast(suffix.count))
            if let num = Double(numStr) {
                return Int64(num * multiplier)
            }
        }
        return nil
    }

    private static func parseTargetDate(_ raw: String, referenceDate: Date) -> (date: Date, hasTimeComponent: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. ISO-8601 (with or without fractional seconds)
        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoWithFrac.date(from: trimmed) {
            return (d, true)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) {
            return (d, true)
        }

        // 2. Standard date/time formats
        let formats: [(String, Bool)] = [
            ("yyyy-MM-dd HH:mm:ss", true),
            ("yyyy-MM-dd HH:mm", true),
            ("yyyy-MM-dd", false)
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for (fmt, hasTime) in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: trimmed) {
                return (d, hasTime)
            }
        }

        // 3. Relative age string (e.g. "7d", "-7d", "24h", "30m", "60s", "2w", "7 days")
        var ageToken = trimmed.lowercased()
            .replacingOccurrences(of: "ago", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ageToken.hasPrefix("-") || ageToken.hasPrefix("+") {
            ageToken.removeFirst()
        }
        ageToken = ageToken.replacingOccurrences(of: " ", with: "")
        let unitMultipliers: [(String, TimeInterval)] = [
            ("seconds", 1), ("second", 1), ("secs", 1), ("sec", 1), ("s", 1),
            ("minutes", 60), ("minute", 60), ("mins", 60), ("min", 60), ("m", 60),
            ("hours", 3600), ("hour", 3600), ("hrs", 3600), ("hr", 3600), ("h", 3600),
            ("days", 86400), ("day", 86400), ("d", 86400),
            ("weeks", 7 * 86400), ("week", 7 * 86400), ("wks", 7 * 86400), ("wk", 7 * 86400), ("w", 7 * 86400),
            ("months", 30 * 86400), ("month", 30 * 86400), ("mo", 30 * 86400),
            ("years", 365 * 86400), ("year", 365 * 86400), ("yrs", 365 * 86400), ("yr", 365 * 86400), ("y", 365 * 86400)
        ]
        for (unit, seconds) in unitMultipliers where ageToken.hasSuffix(unit) {
            let numStr = String(ageToken.dropLast(unit.count))
            if let amount = Double(numStr) {
                return (referenceDate.addingTimeInterval(-amount * seconds), true)
            }
        }

        // 4. Epoch timestamp
        if let epoch = Double(trimmed) {
            return (Date(timeIntervalSince1970: epoch), true)
        }
        return nil
    }
}

public struct SkipRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var matchMode: RuleMatchMode
    public var scope: RuleScope
    public var predicates: [RulePredicate]

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        matchMode: RuleMatchMode = .all,
        scope: RuleScope = .all,
        predicates: [RulePredicate]
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.matchMode = matchMode
        self.scope = scope
        self.predicates = predicates
    }

    public func matches(
        name: String,
        relativePath: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        modified: Date? = nil,
        referenceDate: Date = Date()
    ) -> Bool {
        guard !predicates.isEmpty else { return false }
        switch matchMode {
        case .all:
            return predicates.allSatisfy {
                $0.matches(name: name, relativePath: relativePath, isDirectory: isDirectory, size: size, modified: modified, referenceDate: referenceDate)
            }
        case .any:
            return predicates.contains {
                $0.matches(name: name, relativePath: relativePath, isDirectory: isDirectory, size: size, modified: modified, referenceDate: referenceDate)
            }
        case .none:
            return !predicates.contains {
                $0.matches(name: name, relativePath: relativePath, isDirectory: isDirectory, size: size, modified: modified, referenceDate: referenceDate)
            }
        }
    }

    var canEvaluateAncestorDirectoriesSafely: Bool {
        matchMode != .none && predicates.allSatisfy { $0.dependsOnlyOnNameOrPath }
    }
}

// MARK: - ASCII File Extensions

public enum AsciiFileExtensions {
    public static let defaultList: [String] = [
        "txt", "md", "json", "xml", "html", "htm", "css", "js", "ts",
        "swift", "py", "rb", "php", "sh", "yaml", "yml", "ini", "conf",
        "cfg", "csv", "log", "sql", "svg"
    ]

    public static let defaultSet: Set<String> = Set(defaultList)

    public static func normalizedSet(from extensions: [String]) -> Set<String> {
        Set(
            extensions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .map { ($0.hasPrefix(".") && $0.count > 1) ? String($0.dropFirst()) : $0 }
                .filter { !$0.isEmpty }
        )
    }

    public static func isAsciiTransferFile(_ name: String, extensions: Set<String> = defaultSet) -> Bool {
        let baseName = (name as NSString).lastPathComponent
        guard let dot = baseName.lastIndex(of: "."), dot != baseName.startIndex else { return false }
        let ext = String(baseName[baseName.index(after: dot)...]).lowercased()
        return extensions.contains(ext)
    }
}

// MARK: - FileRulesStore

private final class DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

public final class FileRulesStore: @unchecked Sendable {
    public static let defaultRulesKey = "com.aethernative.AetherTransfer.skipRules"
    public static let defaultAsciiExtensionsKey = "com.aethernative.AetherTransfer.asciiExtensions"

    private let lock = NSLock()
    private let defaultsBox: DefaultsBox
    public let rulesKey: String
    public let asciiExtensionsKey: String

    public init(
        suiteName: String? = nil,
        rulesKey: String = FileRulesStore.defaultRulesKey,
        asciiExtensionsKey: String = FileRulesStore.defaultAsciiExtensionsKey
    ) {
        let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard
        self.defaultsBox = DefaultsBox(defaults)
        self.rulesKey = rulesKey
        self.asciiExtensionsKey = asciiExtensionsKey
    }

    public init(
        userDefaults: UserDefaults,
        rulesKey: String = FileRulesStore.defaultRulesKey,
        asciiExtensionsKey: String = FileRulesStore.defaultAsciiExtensionsKey
    ) {
        self.defaultsBox = DefaultsBox(userDefaults)
        self.rulesKey = rulesKey
        self.asciiExtensionsKey = asciiExtensionsKey
    }

    public static let defaultRules: [SkipRule] = [
        SkipRule(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
            name: "macOS .DS_Store",
            isEnabled: true,
            matchMode: .all,
            scope: .all,
            predicates: [RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!, field: .name, op: .is, value: ".DS_Store")]
        ),
        SkipRule(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
            name: "Git Metadata (.git)",
            isEnabled: true,
            matchMode: .any,
            scope: .all,
            predicates: [
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000002")!, field: .name, op: .is, value: ".git"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000003")!, field: .path, op: .beginsWith, value: ".git/"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000004")!, field: .path, op: .contains, value: "/.git/"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000005")!, field: .path, op: .endsWith, value: "/.git")
            ]
        ),
        SkipRule(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
            name: "Node Modules (node_modules)",
            isEnabled: true,
            matchMode: .any,
            scope: .transfersAndSync,
            predicates: [
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000006")!, field: .name, op: .is, value: "node_modules"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000007")!, field: .path, op: .beginsWith, value: "node_modules/"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000008")!, field: .path, op: .contains, value: "/node_modules/"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-000000000009")!, field: .path, op: .endsWith, value: "/node_modules")
            ]
        ),
        SkipRule(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!,
            name: "Subversion (.svn)",
            isEnabled: true,
            matchMode: .any,
            scope: .transfersAndSync,
            predicates: [
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-00000000000A")!, field: .name, op: .is, value: ".svn"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-00000000000B")!, field: .path, op: .beginsWith, value: ".svn/"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-00000000000C")!, field: .path, op: .contains, value: "/.svn/"),
                RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-00000000000D")!, field: .path, op: .endsWith, value: "/.svn")
            ]
        ),
        SkipRule(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!,
            name: "Vim Swap Files (*.swp)",
            isEnabled: true,
            matchMode: .all,
            scope: .transfersAndSync,
            predicates: [RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-00000000000E")!, field: .name, op: .matchesGlob, value: "*.swp")]
        ),
        SkipRule(
            id: UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!,
            name: "macOS Resource Forks (._*)",
            isEnabled: true,
            matchMode: .all,
            scope: .all,
            predicates: [RulePredicate(id: UUID(uuidString: "B1000000-0000-0000-0000-00000000000F")!, field: .name, op: .matchesGlob, value: "._*")]
        )
    ]

    public func loadRules() -> [SkipRule] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaultsBox.defaults.data(forKey: rulesKey),
              let decoded = try? JSONDecoder().decode([SkipRule].self, from: data) else {
            return Self.defaultRules
        }
        return decoded
    }

    public func saveRules(_ rules: [SkipRule]) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(rules) {
            defaultsBox.defaults.set(data, forKey: rulesKey)
        }
    }

    @discardableResult
    public func resetRulesToDefaults() -> [SkipRule] {
        saveRules(Self.defaultRules)
        return Self.defaultRules
    }

    public func loadAsciiExtensions() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaultsBox.defaults.data(forKey: asciiExtensionsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return AsciiFileExtensions.defaultList
        }
        return decoded
    }

    public func saveAsciiExtensions(_ extensions: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let cleaned = extensions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { ($0.hasPrefix(".") && $0.count > 1) ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
        if let data = try? JSONEncoder().encode(cleaned) {
            defaultsBox.defaults.set(data, forKey: asciiExtensionsKey)
        }
    }

    public func isAsciiTransferFile(_ name: String) -> Bool {
        let extensions = AsciiFileExtensions.normalizedSet(from: loadAsciiExtensions())
        return AsciiFileExtensions.isAsciiTransferFile(name, extensions: extensions)
    }

    public static func isAsciiTransferFile(_ name: String) -> Bool {
        AsciiFileExtensions.isAsciiTransferFile(name)
    }

    public func shouldSkip(
        name: String,
        relativePath: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        modified: Date? = nil,
        scope: RuleScope = .transfersAndSync,
        referenceDate: Date = Date()
    ) -> Bool {
        let rules = loadRules()
        return Self.matchesAny(
            rules: rules,
            name: name,
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: size,
            modified: modified,
            scope: scope,
            referenceDate: referenceDate
        )
    }

    public static func matchesAny(
        rules: [SkipRule],
        name: String,
        relativePath: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        modified: Date? = nil,
        scope: RuleScope = .transfersAndSync,
        referenceDate: Date = Date()
    ) -> Bool {
        let enabledRules = rules.filter { $0.isEnabled && $0.scope.applies(to: scope) }
        return shouldSkipItem(
            relativePath: relativePath,
            isDirectory: isDirectory,
            size: size,
            modified: modified,
            enabledRules: enabledRules,
            skippedDirectoryPrefixes: [],
            referenceDate: referenceDate
        )
    }

    /// Evaluates whether an item (or any of its ancestor directories) matches `enabledRules`.
    public static func shouldSkipItem(
        relativePath: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date?,
        enabledRules: [SkipRule],
        skippedDirectoryPrefixes: Set<String> = [],
        referenceDate: Date = Date()
    ) -> Bool {
        guard !enabledRules.isEmpty else { return false }

        var cleanRel = relativePath
        if cleanRel.hasPrefix("/") { cleanRel.removeFirst() }
        guard !cleanRel.isEmpty else { return false }

        let components = cleanRel.split(separator: "/").map(String.init)
        let itemName = components.last ?? cleanRel

        var prefix = ""
        for idx in 0..<max(0, components.count - 1) {
            let component = components[idx]
            prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
            if skippedDirectoryPrefixes.contains(prefix) {
                return true
            }
            for rule in enabledRules where rule.canEvaluateAncestorDirectoriesSafely {
                if rule.matches(
                    name: component,
                    relativePath: prefix,
                    isDirectory: true,
                    size: 0,
                    modified: nil,
                    referenceDate: referenceDate
                ) {
                    return true
                }
            }
        }

        for rule in enabledRules {
            if rule.matches(
                name: itemName,
                relativePath: cleanRel,
                isDirectory: isDirectory,
                size: size,
                modified: modified,
                referenceDate: referenceDate
            ) {
                return true
            }
        }
        return false
    }

    /// Filters a walked local file tree against active skip rules, excluding skipped directories and their descendants.
    public static func filterLocalItems(
        _ items: [LocalFileItem],
        rules: [SkipRule],
        scope: RuleScope = .transfersAndSync,
        referenceDate: Date = Date()
    ) -> [LocalFileItem] {
        let enabledRules = rules.filter { $0.isEnabled && $0.scope.applies(to: scope) }
        guard !enabledRules.isEmpty else { return items }

        var skippedDirs: Set<String> = []
        for item in items where item.isDirectory {
            var rel = item.relativePath
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty else { continue }
            let name = (rel as NSString).lastPathComponent
            if enabledRules.contains(where: {
                $0.matches(
                    name: name,
                    relativePath: rel,
                    isDirectory: true,
                    size: item.size,
                    modified: item.modified,
                    referenceDate: referenceDate
                )
            }) {
                skippedDirs.insert(rel)
            }
        }

        return items.filter { item in
            !shouldSkipItem(
                relativePath: item.relativePath,
                isDirectory: item.isDirectory,
                size: item.size,
                modified: item.modified,
                enabledRules: enabledRules,
                skippedDirectoryPrefixes: skippedDirs,
                referenceDate: referenceDate
            )
        }
    }
}
