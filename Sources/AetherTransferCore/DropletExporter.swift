import Foundation

// MARK: - URL Scheme & Finder Droplet Command Parser

public enum AetherURLCommandError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedScheme(String)
    case invalidAction(String)
    case missingOrInvalidProfileId
    case missingHost
    case invalidRemotePath

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return L10n.tr("不支持的 URL 协议：\(scheme)", "Unsupported URL scheme: \(scheme)")
        case .invalidAction(let action):
            return L10n.tr("无效的 URL 操作：\(action)", "Invalid URL command action: \(action)")
        case .missingOrInvalidProfileId:
            return L10n.tr("缺少或无效的服务器配置 ID。", "Missing or invalid server profile ID.")
        case .missingHost:
            return L10n.tr("连接 URL 缺少主机地址。", "Connection URL is missing a host.")
        case .invalidRemotePath:
            return L10n.tr("远程路径不合法。", "Invalid remote path.")
        }
    }
}

public enum AetherURLCommand: Equatable, Sendable {
    case upload(profileId: UUID, remotePath: String, localURLs: [URL])
    case connect(ServerProfile)
    case connectProfile(profileId: UUID)

    public static func parse(
        _ url: URL,
        savedProfiles: [ServerProfile] = [],
        additionalLocalURLs: [URL] = []
    ) throws -> AetherURLCommand {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme?.lowercased() else {
            throw AetherURLCommandError.unsupportedScheme("")
        }

        if rawScheme == "aethertransfer" {
            let action = resolveCustomAction(components: components)
            let queryItems = components.queryItems ?? []

            switch action {
            case "upload":
                guard let idRaw = queryItems.first(where: { $0.name == "profileId" })?.value,
                      let profileId = UUID(uuidString: idRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw AetherURLCommandError.missingOrInvalidProfileId
                }

                let rawRemote = queryItems.first(where: { $0.name == "remotePath" })?.value ?? "/"
                let remotePath: String
                do {
                    try RemotePath.validate(rawRemote)
                    remotePath = rawRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "/"
                        : RemotePath.normalize(rawRemote)
                } catch {
                    throw AetherURLCommandError.invalidRemotePath
                }

                var collectedURLs: [URL] = []
                for item in queryItems where item.name == "files" || item.name == "file" {
                    guard let value = item.value, !value.isEmpty else { continue }
                    collectedURLs.append(contentsOf: parseFileQueryValue(value))
                }
                collectedURLs.append(contentsOf: additionalLocalURLs)
                return .upload(profileId: profileId, remotePath: remotePath, localURLs: deduplicatedFileURLs(collectedURLs))

            case "connect":
                guard let idRaw = queryItems.first(where: { $0.name == "profileId" })?.value,
                      let profileId = UUID(uuidString: idRaw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw AetherURLCommandError.missingOrInvalidProfileId
                }
                if let matched = savedProfiles.first(where: { $0.id == profileId }) {
                    return .connect(matched)
                }
                return .connectProfile(profileId: profileId)

            default:
                throw AetherURLCommandError.invalidAction(action)
            }
        }

        let protocolKind: TransferProtocol
        switch rawScheme {
        case "sftp": protocolKind = .sftp
        case "ftp": protocolKind = .ftp
        case "ftps": protocolKind = .ftps
        case "ftpes": protocolKind = .ftpsExplicit
        case "webdav", "dav": protocolKind = .webdav
        case "webdavs", "davs": protocolKind = .webdavs
        default:
            throw AetherURLCommandError.unsupportedScheme(rawScheme)
        }

        guard let host = components.host, !host.isEmpty else {
            throw AetherURLCommandError.missingHost
        }

        let port = components.port ?? protocolKind.defaultPort
        // Never persist URL userinfo password into ServerProfile or display fields.
        let username: String = {
            if let user = components.user, !user.isEmpty {
                return user
            }
            switch protocolKind {
            case .ftp, .ftps, .ftpsExplicit:
                return "anonymous"
            default:
                return NSUserName()
            }
        }()

        let rawPath = components.path
        let initialPath: String
        do {
            try RemotePath.validate(rawPath)
            initialPath = rawPath.isEmpty ? "/" : RemotePath.normalize(rawPath)
        } catch {
            throw AetherURLCommandError.invalidRemotePath
        }

        let profile = ServerProfile(
            name: host,
            host: host,
            port: port,
            username: username,
            protocolKind: protocolKind,
            initialPath: initialPath
        )
        return .connect(profile)
    }

    /// Parses URLs and optional CLI/Finder file arguments passed to `NSApplication`.
    public static func parseOpenRequest(
        urls: [URL],
        savedProfiles: [ServerProfile] = [],
        commandLineArguments: [String] = []
    ) throws -> AetherURLCommand? {
        var actionURL: URL?
        var fileURLs: [URL] = []

        for url in urls {
            if url.isFileURL {
                fileURLs.append(url)
            } else if actionURL == nil {
                actionURL = url
            }
        }

        for arg in commandLineArguments {
            if arg.isEmpty || arg.hasPrefix("-") { continue }
            if let maybeURL = URL(string: arg), let scheme = maybeURL.scheme?.lowercased(),
               ["aethertransfer", "sftp", "ftp", "ftps", "ftpes", "webdav", "webdavs"].contains(scheme) {
                if actionURL == nil { actionURL = maybeURL }
            } else {
                fileURLs.append(URL(fileURLWithPath: arg))
            }
        }

        guard let targetURL = actionURL else { return nil }
        return try parse(targetURL, savedProfiles: savedProfiles, additionalLocalURLs: fileURLs)
    }

    public static func buildUploadURL(
        profileId: UUID,
        remotePath: String,
        localURLs: [URL] = []
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "aethertransfer"
        components.host = "upload"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "profileId", value: profileId.uuidString),
            URLQueryItem(name: "remotePath", value: RemotePath.normalize(remotePath))
        ]
        for localURL in localURLs {
            items.append(URLQueryItem(name: "files", value: localURL.path))
        }
        components.queryItems = items
        return components.url
    }

    private static func resolveCustomAction(components: URLComponents) -> String {
        if let host = components.host, !host.isEmpty {
            return host.lowercased()
        }
        let parts = components.path.split(separator: "/").map(String.init)
        return (parts.first ?? "").lowercased()
    }

    private static func parseFileQueryValue(_ value: String) -> [URL] {
        let fm = FileManager.default
        if value.contains(",") && !fm.fileExists(atPath: value) {
            return value.split(separator: ",").compactMap { segment in
                let trimmed = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return fileURLFromToken(trimmed)
            }
        }
        if let single = fileURLFromToken(value) {
            return [single]
        }
        return []
    }

    private static func fileURLFromToken(_ token: String) -> URL? {
        if token.hasPrefix("file://"), let parsed = URL(string: token), parsed.isFileURL {
            return parsed
        }
        return URL(fileURLWithPath: token)
    }

    private static func deduplicatedFileURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }
}

// MARK: - Standalone macOS Droplet Exporter

public enum DropletExporter {
    public static let mainBundleIdentifier = "com.aethernative.AetherTransfer"
    public static let dropletExecutableName = "AetherDroplet"

    @discardableResult
    public static func exportDroplet(
        for profile: ServerProfile,
        remotePath: String = "/",
        destinationAppURL: URL
    ) throws -> URL {
        let effectiveRemote = remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (profile.initialPath.isEmpty ? "/" : profile.initialPath)
            : remotePath
        try RemotePath.validate(effectiveRemote)
        let normalizedRemote = RemotePath.normalize(effectiveRemote)

        let fm = FileManager.default
        let contentsURL = destinationAppURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        if fm.fileExists(atPath: destinationAppURL.path) {
            try fm.removeItem(at: destinationAppURL)
        }
        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // Copy AppIcon.icns from main bundle when available
        var hasIcon = false
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            let destIconURL = resourcesURL.appendingPathComponent("AppIcon.icns")
            try? fm.copyItem(at: iconURL, to: destIconURL)
            hasIcon = fm.fileExists(atPath: destIconURL.path)
        }

        let shortId = String(profile.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let bundleIdentifier = "\(mainBundleIdentifier).droplet.\(shortId)"

        let rawTitle = destinationAppURL.deletingPathExtension().lastPathComponent
        let fallbackName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (profile.host.isEmpty ? "AetherTransfer Droplet" : profile.host)
            : profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawTitle.isEmpty ? fallbackName : rawTitle

        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": dropletExecutableName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleSignature": "????",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "CFBundleDocumentTypes": [
                [
                    "CFBundleTypeName": "Dropped Items",
                    "CFBundleTypeRole": "Viewer",
                    "LSHandlerRank": "Alternate",
                    "LSItemContentTypes": ["public.item", "public.data", "public.folder"]
                ]
            ]
        ]
        if hasIcon {
            plist["CFBundleIconFile"] = "AppIcon"
        }

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        try Data("APPL????".utf8).write(to: contentsURL.appendingPathComponent("PkgInfo"), options: .atomic)

        let script = buildLauncherScript(profileId: profile.id, remotePath: normalizedRemote)
        let executableURL = macOSURL.appendingPathComponent(dropletExecutableName)
        try Data(script.utf8).write(to: executableURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        return destinationAppURL
    }

    static func percentEncodeQueryComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func buildLauncherScript(profileId: UUID, remotePath: String) -> String {
        let encodedProfileId = profileId.uuidString
        let encodedRemotePath = percentEncodeQueryComponent(remotePath)

        return """
        #!/bin/sh
        set -eu

        PROFILE_ID="\(encodedProfileId)"
        REMOTE_PATH_ENC="\(encodedRemotePath)"
        TARGET_BUNDLE_ID="\(mainBundleIdentifier)"

        encode_uri() {
          printf '%s' "$1" | LC_ALL=C od -An -tx1 -v | LC_ALL=C awk '
            BEGIN {
              for (i = 0; i < 256; i++) {
                hex[sprintf("%02x", i)] = sprintf("%c", i)
              }
            }
            {
              for (i = 1; i <= NF; i++) {
                b = tolower($i)
                c = hex[b]
                if (c ~ /^[A-Za-z0-9_.~-]$/) {
                  printf "%s", c
                } else {
                  printf "%%%s", toupper(b)
                }
              }
            }'
        }

        QUERY="profileId=${PROFILE_ID}&remotePath=${REMOTE_PATH_ENC}"
        HAS_FILES=0

        for arg in "$@"; do
          case "$arg" in
            -psn_*|"") continue ;;
          esac
          if [ -e "$arg" ]; then
            ABS_PATH=$(cd "$(dirname -- "$arg")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename -- "$arg")") || ABS_PATH="$arg"
          else
            ABS_PATH="$arg"
          fi
          ENC_PATH=$(encode_uri "$ABS_PATH")
          QUERY="${QUERY}&files=${ENC_PATH}"
          HAS_FILES=1
        done

        TARGET_URL="aethertransfer://upload?${QUERY}"

        if [ "$HAS_FILES" -eq 1 ]; then
          if ! open -b "$TARGET_BUNDLE_ID" "$TARGET_URL" 2>/dev/null; then
            open "$TARGET_URL" --args "$@"
          fi
        else
          if ! open -b "$TARGET_BUNDLE_ID" "$TARGET_URL" 2>/dev/null; then
            open "$TARGET_URL"
          fi
        fi
        """
    }
}
