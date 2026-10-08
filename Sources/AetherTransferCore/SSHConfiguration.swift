import Darwin
import Foundation

public enum SSHConfigurationError: Error, LocalizedError, Sendable {
    case malformed, limitExceeded, unreadable, privateKeyRequired, preparationRequired, authenticationDisabled
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .malformed: L10n.text("SSH 配置格式不正确，请检查配置文件。")
        case .limitExceeded: L10n.text("SSH 配置超过读取限制，连接已停止。")
        case .unreadable: L10n.text("无法读取 SSH 配置，请检查文件权限。")
        case .privateKeyRequired: L10n.text("SSH 配置没有可用的私钥文件，请手动选择。")
        case .preparationRequired: L10n.text("请先解析 SSH 配置，再连接服务器。")
        case .authenticationDisabled: L10n.text("SSH 配置禁止所选认证方式，请检查配置或更换认证方式。")
        case .unsupported(let option): L10n.format("SSH 配置暂不支持“%@”，请使用手动连接资料。", option)
        }
    }
}

/// Non-secret identity to which an explicitly approved fingerprint belongs.
public struct SSHHostIdentity: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public init(profile: ServerProfile) { host = profile.host; port = profile.port; username = profile.username }
}

public struct SSHConfigurationEnvironment: Sendable {
    public let home: URL
    public let systemFile: URL?
    public let localUsername: String
    public let variables: [String: String]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemFile: URL? = URL(fileURLWithPath: "/etc/ssh/ssh_config"),
                localUsername: String = NSUserName(), variables: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home; self.systemFile = systemFile; self.localUsername = localUsername; self.variables = variables
    }
}

/// Immutable endpoint snapshot. Approving a key does not reread config between
/// displaying a fingerprint and connecting to its endpoint.
public struct SSHPreparedConnection: Sendable {
    public let source: ServerProfile
    public let profile: ServerProfile
    public func withSavedSource(_ saved: ServerProfile) throws -> Self {
        guard saved.id == source.id, saved.credentialIdentity == source.credentialIdentity,
              saved.initialPath == source.initialPath else { throw TransferError.invalidConnection }
        var profile = profile
        profile.name = saved.name; profile.group = saved.group
        profile.credentialID = saved.credentialID; profile.retiredCredentialIDs = saved.retiredCredentialIDs
        if saved.trustedHostKey != source.trustedHostKey {
            profile.trustedHostKey = nil; profile.sshTrustedEndpoint = nil
        }
        return Self(source: saved, profile: profile)
    }
    public func trusting(_ key: String) -> Self {
        var source = source, profile = profile
        source.trustedHostKey = key; profile.trustedHostKey = key
        source.sshTrustedEndpoint = SSHHostIdentity(profile: profile)
        profile.sshTrustedEndpoint = source.sshTrustedEndpoint
        return Self(source: source, profile: profile)
    }
}

public enum SSHConnectionPreparation {
    public static func prepare(_ profile: ServerProfile) async throws -> SSHPreparedConnection {
        let worker = Task.detached { try resolve(profile, environment: SSHConfigurationEnvironment()) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    /// File IO is synchronous here for isolated tests; callers use prepare().
    public static func resolve(_ source: ServerProfile, environment: SSHConfigurationEnvironment) throws -> SSHPreparedConnection {
        try Task.checkCancellation(); try source.validate()
        guard source.protocolKind == .sftp, source.sshConfiguration == true else {
            var profile = source
            if source.protocolKind == .sftp, let endpoint = source.sshTrustedEndpoint, endpoint != SSHHostIdentity(profile: source) {
                profile.trustedHostKey = nil; profile.sshTrustedEndpoint = nil
            }
            return SSHPreparedConnection(source: source, profile: profile)
        }
        var overrides: [String: String] = [:]
        if !source.username.isEmpty { overrides["user"] = source.username }
        if source.sshUseConfiguredPort == false { overrides["port"] = String(source.port) }
        var reader = SSHConfigurationReader(alias: source.host, environment: environment, overrides: overrides)
        try reader.load()
        var profile = source
        profile.host = try reader.expandHostname()
        profile.username = source.username.isEmpty ? reader.scalars["user"] ?? environment.localUsername : source.username
        if source.sshUseConfiguredPort != false {
            guard let port = Int(reader.scalars["port"] ?? "22"), (1...65535).contains(port) else { throw SSHConfigurationError.malformed }
            profile.port = port
        }
        let mechanism = source.effectiveSSHAuthentication
        if (mechanism == .password && reader.scalars["passwordauthentication"] == "no") ||
           (mechanism != .password && reader.scalars["pubkeyauthentication"] == "no") {
            throw SSHConfigurationError.authenticationDisabled
        }
        if let allowed = reader.scalars["preferredauthentications"]?.split(separator: ","),
           !allowed.contains(mechanism == .password ? "password" : "publickey") { throw SSHConfigurationError.authenticationDisabled }
        if mechanism == .agent && (reader.scalars["identityagent"] == "none" || reader.scalars["identitiesonly"] == "yes") {
            throw SSHConfigurationError.authenticationDisabled
        }
        if mechanism == .privateKey {
            let paths = source.privateKeyPath.isEmpty ? reader.identities : [source.privateKeyPath]
            var selected: String?
            for value in paths where value != "none" {
                try Task.checkCancellation()
                let path = try reader.expand(value, host: profile.host, user: profile.username, port: profile.port)
                let absolute = path.hasPrefix("/") ? path : environment.home.appendingPathComponent(path).path
                var info = stat()
                if stat(absolute, &info) == 0 && info.st_mode & S_IFMT == S_IFREG { selected = absolute; break }
            }
            guard let selected else { throw SSHConfigurationError.privateKeyRequired }
            profile.privateKeyPath = selected
        }
        profile.sshConfiguration = nil; profile.sshUseConfiguredPort = nil
        // Legacy pins survive only if resolution has not changed the endpoint.
        let trustedEndpoint = source.sshTrustedEndpoint ?? SSHHostIdentity(profile: source)
        if trustedEndpoint != SSHHostIdentity(profile: profile) { profile.trustedHostKey = nil; profile.sshTrustedEndpoint = nil }
        try profile.validate()
        return SSHPreparedConnection(source: source, profile: profile)
    }
}

private struct SSHConfigurationReader {
    let alias: String
    let environment: SSHConfigurationEnvironment
    var scalars: [String: String] = [:]
    var identities: [String] = []
    private var active = true
    private var stack: Set<String> = []
    private var files = 0
    private var bytes = 0

    init(alias: String, environment: SSHConfigurationEnvironment, overrides: [String: String]) {
        self.alias = alias; self.environment = environment; scalars = overrides
    }
    mutating func load() throws {
        let base = environment.home.appendingPathComponent(".ssh")
        try read(base.appendingPathComponent("config"), base: base, optional: true)
        active = true
        if let system = environment.systemFile { try read(system, base: system.deletingLastPathComponent(), optional: true) }
    }

    private mutating func read(_ file: URL, base: URL, optional: Bool) throws {
        try Task.checkCancellation()
        guard stack.count < 8, files < 32 else { throw SSHConfigurationError.limitExceeded }
        // Nonblocking open and fstat prevent a config FIFO/device from hanging.
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if optional && errno == ENOENT { return }
            throw SSHConfigurationError.unreadable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (info.st_uid == geteuid() || info.st_uid == 0), info.st_mode & 0o022 == 0 else { throw SSHConfigurationError.unreadable }
        guard info.st_size >= 0, info.st_size <= 256 * 1024 else { throw SSHConfigurationError.limitExceeded }
        let identity = "\(info.st_dev):\(info.st_ino)"
        guard stack.insert(identity).inserted else { throw SSHConfigurationError.limitExceeded }
        defer { stack.remove(identity) }
        files += 1
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw SSHConfigurationError.unreadable }
            if count == 0 { break }
            bytes += count
            guard bytes <= 1024 * 1024, data.count + count <= 256 * 1024 else { throw SSHConfigurationError.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else { throw SSHConfigurationError.malformed }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try Task.checkCancellation()
            guard line.utf8.count <= 8192 else { throw SSHConfigurationError.limitExceeded }
            let words = try Self.words(String(line))
            guard let first = words.first else { continue }
            let key = first.lowercased(), values = Array(words.dropFirst())
            guard !values.isEmpty else { throw SSHConfigurationError.malformed }
            if key == "host" { active = Self.matches(alias, patterns: values); continue }
            // Match can change the active block independently of preceding Host.
            // Never shell out to ssh -G (Match exec would execute local commands).
            if key == "match" { throw SSHConfigurationError.unsupported("Match") }
            guard active else { continue }
            if key == "include" {
                for value in values {
                    let expanded = try expand(value, host: expandHostname(), user: scalars["user"] ?? environment.localUsername,
                                              port: Int(scalars["port"] ?? "22") ?? 22)
                    let path = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
                    let parentActive = active
                    for included in try Self.includes(path) {
                        try read(included, base: base, optional: true)
                        active = parentActive
                    }
                }
                continue
            }
            if key == "identityfile" {
                guard values.count == 1, identities.count < 32 else { throw SSHConfigurationError.limitExceeded }
                if !identities.contains(values[0]) { identities.append(values[0]) }
                continue
            }
            // Session-only options have no effect on an SFTP file request.
            if ["sendenv", "setenv", "requesttty", "forwardx11", "forwardx11trusted", "forwardagent", "loglevel", "visualhostkey"].contains(key) { continue }
            guard ["hostname", "user", "port", "passwordauthentication", "pubkeyauthentication", "preferredauthentications", "identitiesonly", "identityagent"].contains(key) else {
                // Never reflect arbitrary configuration text into an error: a
                // wrong input file could contain a private key or credentials.
                let named = ["proxycommand", "proxyjump", "certificatefile", "pkcs11provider", "securitykeyprovider",
                             "hostkeyalias", "userknownhostsfile", "globalknownhostsfile", "stricthostkeychecking",
                             "kexalgorithms", "ciphers", "hostkeyalgorithms", "canonicalizehostname", "localcommand",
                             "remotecommand", "knownhostscommand", "addkeystoagent", "usekeychain"]
                throw SSHConfigurationError.unsupported(named.contains(key) ? key : "SSH option")
            }
            guard values.count == 1 else { throw SSHConfigurationError.malformed }
            if scalars[key] != nil { continue } // OpenSSH: first scalar wins.
            let value = values[0]
            if ["passwordauthentication", "pubkeyauthentication", "identitiesonly"].contains(key) && !["yes", "no"].contains(value) { throw SSHConfigurationError.malformed }
            if key == "identityagent", value != "none" { throw SSHConfigurationError.unsupported("IdentityAgent") }
            scalars[key] = value
        }
    }

    private static func words(_ line: String) throws -> [String] {
        var words: [String] = [], word = "", quoted = false, escaped = false, started = false, equalsUsed = false
        for char in line {
            if escaped { word.append(char); escaped = false; started = true; continue }
            if char == "\\" { escaped = true; started = true; continue }
            if char == "\"" { quoted.toggle(); started = true; continue }
            if !quoted && char == "#" { break }
            if !quoted && (char.isWhitespace || (char == "=" && (words.isEmpty || (words.count == 1 && !started)))) {
                if char == "=" {
                    guard !equalsUsed else { throw SSHConfigurationError.malformed }
                    equalsUsed = true
                }
                if started { words.append(word); word = ""; started = false }
            } else { word.append(char); started = true }
        }
        guard !quoted, !escaped else { throw SSHConfigurationError.malformed }
        if started { words.append(word) }
        return words
    }

    private static func matches(_ host: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            let negative = pattern.hasPrefix("!"), value = negative ? String(pattern.dropFirst()) : pattern
            if fnmatch(value.lowercased(), host.lowercased(), 0) == 0 {
                if negative { return false }
                matched = true
            }
        }
        return matched
    }

    func expand(_ raw: String, host: String, user: String, port: Int) throws -> String {
        var value = raw
        if value == "~" { value = environment.home.path }
        else if value.hasPrefix("~/") { value = environment.home.path + String(value.dropFirst()) }
        else if value.hasPrefix("~") { throw SSHConfigurationError.unsupported("~user") }
        var result = "", index = value.startIndex
        while index < value.endIndex {
            let char = value[index]; index = value.index(after: index)
            if char == "%" {
                guard index < value.endIndex else { throw SSHConfigurationError.malformed }
                let token = value[index]; index = value.index(after: index)
                let tokens: [Character: String] = ["%": "%", "h": host, "n": alias, "r": user, "u": environment.localUsername, "d": environment.home.path, "p": String(port)]
                guard let replacement = tokens[token] else { throw SSHConfigurationError.unsupported("% token") }
                result += replacement
            } else if char == "$", index < value.endIndex, value[index] == "{" {
                let start = value.index(after: index)
                guard let end = value[start...].firstIndex(of: "}"), let replacement = environment.variables[String(value[start..<end])] else { throw SSHConfigurationError.malformed }
                result += replacement; index = value.index(after: end)
            } else { result.append(char) }
            guard result.utf8.count <= 4096 else { throw SSHConfigurationError.limitExceeded }
        }
        guard !result.utf8.contains(0), !result.contains("\n"), !result.contains("\r") else { throw SSHConfigurationError.malformed }
        return result
    }

    func expandHostname() throws -> String {
        let raw = scalars["hostname"] ?? alias
        // Hostname supports only %% and %h, without environment expansion.
        var result = "", iterator = raw.makeIterator()
        while let char = iterator.next() {
            if char == "%" {
                guard let token = iterator.next(), token == "%" || token == "h" else { throw SSHConfigurationError.unsupported("Hostname token") }
                result += token == "%" ? "%" : alias
            } else { result.append(char) }
            guard result.utf8.count <= 4096 else { throw SSHConfigurationError.limitExceeded }
        }
        guard !raw.contains("${") else { throw SSHConfigurationError.unsupported("Hostname environment variable") }
        return result
    }

    private static func includes(_ path: String) throws -> [URL] {
        let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent()
        guard !parent.path.contains(where: { "*?[".contains($0) }) else { throw SSHConfigurationError.unsupported("Include directory pattern") }
        let pattern = url.lastPathComponent
        if !pattern.contains(where: { "*?[".contains($0) }) { return [url] }
        guard let directory = opendir(parent.path) else {
            if errno == ENOENT { return [] }
            throw SSHConfigurationError.unreadable
        }
        defer { closedir(directory) }
        var results: [URL] = [], entries = 0
        while let entry = readdir(directory) {
            try Task.checkCancellation(); entries += 1
            guard entries <= 4096 else { throw SSHConfigurationError.limitExceeded }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name != ".", name != "..", fnmatch(pattern, name, 0) == 0 {
                guard results.count < 32 else { throw SSHConfigurationError.limitExceeded }
                results.append(parent.appendingPathComponent(name))
            }
        }
        return results.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }
}
