import Foundation

public enum BookmarkImporterError: Error, LocalizedError, Sendable {
    case unsupportedFormat(String)
    case malformedData(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return L10n.tr("不支持的书签导入格式：\(ext)", "Unsupported bookmark import format: \(ext)")
        case .malformedData(let detail):
            return L10n.tr("无法解析导入的书签数据：\(detail)", "Unable to parse imported bookmark data: \(detail)")
        }
    }
}

public enum BookmarkImporter {
    // MARK: - Auto-detect File & Local Config Importers

    public static func importFromFile(at url: URL) throws -> [ImportedServerItem] {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "duck":
            return try importCyberduckBookmark(data: data)
        case "exportedfavorites", "inetloc", "ftploc":
            return try importTransmitOrNova(data: data)
        case "xml":
            if let text = String(data: data.prefix(512), encoding: .utf8),
               text.contains("<plist") {
                return try importPlistAutoDetect(data: data)
            }
            return try importFileZillaXML(data: data)
        case "plist":
            return try importPlistAutoDetect(data: data)
        case "json":
            let profiles = try ServerProfile.importJSON(data)
            return profiles.map {
                ImportedServerItem(
                    sourceFormat: "AetherTransfer JSON",
                    profile: $0,
                    hasPassword: false,
                    optionalPassword: nil,
                    selected: true
                )
            }
        default:
            if let prefix = String(data: data.prefix(512), encoding: .utf8) {
                let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("<FileZilla3") || trimmed.contains("<Servers") {
                    return try importFileZillaXML(data: data)
                }
                if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
                    let profiles = try ServerProfile.importJSON(data)
                    return profiles.map {
                        ImportedServerItem(sourceFormat: "AetherTransfer JSON", profile: $0)
                    }
                }
            }
            if data.starts(with: Data("bplist".utf8)) ||
                (String(data: data.prefix(512), encoding: .utf8)?.contains("<plist") == true) {
                return try importPlistAutoDetect(data: data)
            }
            throw BookmarkImporterError.unsupportedFormat(ext.isEmpty ? url.lastPathComponent : ext)
        }
    }

    public static func importFromLocalConfigs() -> [ImportedServerItem] {
        importFromLocalConfigs(
            sshConfigURL: SSHConfigParser.defaultConfigURL(),
            awsConfigURL: AWSConfigParser.defaultConfigURL(),
            awsCredentialsURL: AWSConfigParser.defaultCredentialsURL()
        )
    }

    public static func importFromLocalConfigs(
        sshConfigURL: URL,
        awsConfigURL: URL,
        awsCredentialsURL: URL
    ) -> [ImportedServerItem] {
        var results: [ImportedServerItem] = []

        if let sshContent = try? String(contentsOf: sshConfigURL, encoding: .utf8) {
            let sshItems = SSHConfigParser.parse(sshContent).map { entry in
                ImportedServerItem(
                    sourceFormat: "SSH Config",
                    profile: entry.toServerProfile(),
                    hasPassword: false,
                    optionalPassword: nil,
                    selected: true
                )
            }
            results.append(contentsOf: sshItems)
        }

        let awsItems = AWSConfigParser.parseFiles(configURL: awsConfigURL, credentialsURL: awsCredentialsURL)
        results.append(contentsOf: awsItems)
        return results
    }

    // MARK: - FileZilla XML

    public static func importFileZillaXML(data: Data) throws -> [ImportedServerItem] {
        let delegate = FileZillaXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawFileZillaRoot else {
            throw BookmarkImporterError.malformedData("FileZilla XML")
        }
        return delegate.items
    }

    // MARK: - Cyberduck (.duck)

    public static func importCyberduckBookmark(data: Data) throws -> [ImportedServerItem] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dicts: [[String: Any]]
        if let single = plist as? [String: Any] {
            dicts = [single]
        } else if let array = plist as? [[String: Any]] {
            dicts = array
        } else {
            throw BookmarkImporterError.malformedData("Cyberduck .duck")
        }

        var items: [ImportedServerItem] = []
        for dict in dicts {
            let host = stringValue(dict["Hostname"]) ?? stringValue(dict["Server"]) ?? ""
            guard !host.isEmpty else { continue }

            let protoRaw = (stringValue(dict["Protocol"]) ?? "sftp").lowercased()
            let portVal = intValue(dict["Port"])
            let proto = mapCyberduckProtocol(protoRaw, port: portVal)
            let port = portVal ?? proto.defaultPort
            let username = stringValue(dict["Username"]) ?? ""
            let nickname = stringValue(dict["Nickname"]) ?? stringValue(dict["Name"]) ?? ""
            let name = nickname.isEmpty ? host : nickname
            let path = RemotePath.normalize(stringValue(dict["Path"]) ?? "/")
            let keyPath = SSHConfigParser.expandTilde(stringValue(dict["Private Key File"]) ?? "")
            let bucket = stringValue(dict["Bucket"]) ?? ""
            let region = stringValue(dict["Region"]) ?? "us-east-1"

            let group: String
            if let labels = dict["Labels"] as? [String], let first = labels.first, !first.isEmpty {
                group = first
            } else if let label = stringValue(dict["Labels"]), !label.isEmpty {
                group = label
            } else {
                group = "Cyberduck"
            }

            let profile = ServerProfile(
                name: name,
                group: group,
                host: host,
                port: port,
                username: username,
                protocolKind: proto,
                initialPath: path,
                privateKeyPath: keyPath,
                s3Bucket: bucket,
                s3Region: region.isEmpty ? "us-east-1" : region
            )
            items.append(ImportedServerItem(
                sourceFormat: "Cyberduck",
                profile: profile,
                hasPassword: false,
                optionalPassword: nil,
                selected: true
            ))
        }
        return items
    }

    // MARK: - Transmit / Nova (.exportedFavorites / .inetloc / .ftploc)

    public static func importTransmitOrNova(data: Data) throws -> [ImportedServerItem] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        var items: [ImportedServerItem] = []

        func collect(from node: Any, groupStack: [String]) {
            if let array = node as? [Any] {
                for element in array {
                    collect(from: element, groupStack: groupStack)
                }
                return
            }
            guard let dict = node as? [String: Any] else { return }

            var isContainer = false
            if let favorites = dict["TRFavorite"] as? [Any] {
                isContainer = true
                let folderName = stringValue(dict["Name"]) ?? stringValue(dict["Title"])
                let nextStack = folderName.map { groupStack + [$0] } ?? groupStack
                collect(from: favorites, groupStack: nextStack)
            }
            if let favoriteDict = dict["TRFavorite"] as? [String: Any] {
                isContainer = true
                collect(from: favoriteDict, groupStack: groupStack)
            }
            if let favorites = dict["Favorites"] as? [Any] {
                isContainer = true
                let folderName = stringValue(dict["Name"]) ?? stringValue(dict["Title"])
                let nextStack = folderName.map { groupStack + [$0] } ?? groupStack
                collect(from: favorites, groupStack: nextStack)
            }
            if let children = dict["Children"] as? [Any] ?? dict["children"] as? [Any] {
                isContainer = true
                let folderName = stringValue(dict["Name"]) ?? stringValue(dict["Title"])
                let nextStack = folderName.map { groupStack + [$0] } ?? groupStack
                collect(from: children, groupStack: nextStack)
            }
            if let collections = dict["Collections"] as? [Any] {
                isContainer = true
                collect(from: collections, groupStack: groupStack)
            }

            if !isContainer, let item = parseTransmitFavoriteDict(dict, groupStack: groupStack) {
                items.append(item)
            }
        }

        collect(from: plist, groupStack: [])
        return items
    }

    private static func importPlistAutoDetect(data: Data) throws -> [ImportedServerItem] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        if let dict = plist as? [String: Any],
           dict["Hostname"] != nil,
           dict["Protocol"] != nil,
           dict["Server"] == nil,
           dict["URL"] == nil,
           dict["TRFavorite"] == nil {
            return try importCyberduckBookmark(data: data)
        }
        return try importTransmitOrNova(data: data)
    }

    private static func parseTransmitFavoriteDict(_ dict: [String: Any], groupStack: [String]) -> ImportedServerItem? {
        let urlString = stringValue(dict["URL"]) ?? ""
        var parsedURLComponents = urlString.isEmpty ? nil : URLComponents(string: urlString)
        if parsedURLComponents == nil && !urlString.isEmpty, let url = URL(string: urlString) {
            parsedURLComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        }

        let explicitServer = stringValue(dict["Server"]) ?? stringValue(dict["Host"]) ?? stringValue(dict["Hostname"])
        let urlHost = parsedURLComponents?.host
        let host = (explicitServer?.isEmpty == false ? explicitServer : urlHost) ?? ""
        guard !host.isEmpty else { return nil }

        let protoRaw = stringValue(dict["Protocol"]) ?? parsedURLComponents?.scheme ?? ""
        let explicitPort = intValue(dict["Port"]) ?? parsedURLComponents?.port
        let proto = mapTransmitProtocol(protoRaw, port: explicitPort)
        let port = explicitPort ?? proto.defaultPort

        let username = stringValue(dict["Username"])
            ?? stringValue(dict["User"])
            ?? parsedURLComponents?.user
            ?? ""

        let rawPassword = stringValue(dict["Password"]) ?? parsedURLComponents?.password
        let cleanPassword = (rawPassword?.isEmpty == false) ? rawPassword : nil

        let rawPath = stringValue(dict["InitialPath"])
            ?? stringValue(dict["RemotePath"])
            ?? stringValue(dict["Path"])
            ?? parsedURLComponents?.path
            ?? "/"
        let initialPath = RemotePath.normalize(rawPath.isEmpty ? "/" : rawPath)

        let localPath = stringValue(dict["LocalPath"]) ?? stringValue(dict["DefaultLocalPath"]) ?? ""
        let siteURL = sanitizedSiteURL(stringValue(dict["SiteURL"]) ?? stringValue(dict["RootURL"]) ?? "")
        let nickname = stringValue(dict["Nickname"]) ?? stringValue(dict["Name"]) ?? stringValue(dict["Title"]) ?? ""
        let name = nickname.isEmpty ? host : nickname
        let keyPath = SSHConfigParser.expandTilde(stringValue(dict["PrivateKeyPath"]) ?? stringValue(dict["SSHPrivateKey"]) ?? "")
        let bucket = stringValue(dict["Bucket"]) ?? ""
        let region = stringValue(dict["Region"]) ?? "us-east-1"

        let group = groupStack.isEmpty ? (stringValue(dict["Group"]) ?? "Transmit") : groupStack.joined(separator: " / ")

        // Never persist imported passwords into ServerProfile; pass strictly through optionalPassword.
        let profile = ServerProfile(
            name: name,
            group: group,
            host: host,
            port: port,
            username: username,
            protocolKind: proto,
            initialPath: initialPath,
            privateKeyPath: keyPath,
            s3Bucket: bucket,
            s3Region: region.isEmpty ? "us-east-1" : region,
            defaultLocalPath: localPath,
            siteURL: siteURL
        )

        return ImportedServerItem(
            sourceFormat: "Transmit / Nova",
            profile: profile,
            hasPassword: cleanPassword != nil,
            optionalPassword: cleanPassword,
            selected: true
        )
    }

    // MARK: - Protocol & Value Mapping Helpers

    private static func mapCyberduckProtocol(_ raw: String, port: Int?) -> TransferProtocol {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sftp", "ssh":
            return .sftp
        case "ftp":
            return .ftp
        case "ftps-implicit", "ftpsimplicit":
            return .ftps
        case "ftps", "ftpes":
            return port == 990 ? .ftps : .ftpsExplicit
        case "dav", "webdav", "http":
            return .webdav
        case "davs", "webdavs", "https":
            return .webdavs
        case "s3":
            return .s3
        case "b2":
            return .b2
        case "azure", "azureblob":
            return .azureBlob
        case "swift", "openstackswift":
            return .openstackSwift
        default:
            return .sftp
        }
    }

    private static func mapTransmitProtocol(_ raw: String, port: Int?) -> TransferProtocol {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "sftp", "ssh":
            return .sftp
        case "ftp":
            return .ftp
        case "ftps", "ftp with implicit ssl", "ftps implicit":
            return port == 21 ? .ftpsExplicit : .ftps
        case "ftpes", "ftp with tls/ssl", "ftps explicit", "ftps_explicit":
            return .ftpsExplicit
        case "webdav", "dav", "http":
            return .webdav
        case "webdavs", "webdav https", "davs", "https":
            return .webdavs
        case "s3", "amazon s3", "amazons3":
            return .s3
        case "b2", "backblaze b2", "backblazeb2":
            return .b2
        case "azure", "microsoft azure", "azureblob":
            return .azureBlob
        case "swift", "openstack swift", "openstackswift":
            return .openstackSwift
        default:
            return .sftp
        }
    }

    private static func sanitizedSiteURL(_ raw: String) -> String {
        guard !raw.isEmpty, var components = URLComponents(string: raw) else { return raw }
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

// MARK: - FileZilla XML Parser Delegate

private final class FileZillaXMLDelegate: NSObject, XMLParserDelegate {
    var sawFileZillaRoot = false
    var items: [ImportedServerItem] = []

    private var folderStack: [String] = []
    private var capturingFolderName = false
    private var inServer = false
    private var currentElement = ""
    private var buffer = ""

    private var host = ""
    private var port = ""
    private var proto = ""
    private var user = ""
    private var pass = ""
    private var passEncoding = ""
    private var name = ""
    private var remoteDir = ""
    private var localDir = ""
    private var pasvMode = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        buffer = ""

        if elementName == "FileZilla3" || elementName == "Servers" {
            sawFileZillaRoot = true
            capturingFolderName = false
        } else if elementName == "Folder" {
            folderStack.append("")
            capturingFolderName = true
        } else if elementName == "Server" {
            capturingFolderName = false
            inServer = true
            host = ""
            port = ""
            proto = ""
            user = ""
            pass = ""
            passEncoding = ""
            name = ""
            remoteDir = ""
            localDir = ""
            pasvMode = ""
        } else if inServer && elementName == "Pass" {
            passEncoding = (attributeDict["encoding"] ?? "").lowercased()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inServer {
            buffer += string
        } else if capturingFolderName && !folderStack.isEmpty {
            folderStack[folderStack.count - 1] += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if inServer {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "Host": host = trimmed
            case "Port": port = trimmed
            case "Protocol": proto = trimmed
            case "User": user = trimmed
            case "Pass": pass = trimmed
            case "Name": name = trimmed
            case "RemoteDir": remoteDir = trimmed
            case "LocalDir": localDir = trimmed
            case "PasvMode": pasvMode = trimmed
            case "Server":
                inServer = false
                appendServerItem()
            default:
                break
            }
        } else if elementName == "Folder" {
            capturingFolderName = false
            if !folderStack.isEmpty {
                folderStack.removeLast()
            }
        }
        currentElement = ""
        buffer = ""
    }

    private func appendServerItem() {
        guard !host.isEmpty else { return }

        let protocolKind: TransferProtocol
        switch proto {
        case "0": protocolKind = .ftp
        case "1": protocolKind = .sftp
        case "3": protocolKind = .ftpsExplicit
        case "4": protocolKind = .ftps
        default: protocolKind = proto.isEmpty ? .ftp : .ftp
        }

        let resolvedPort = Int(port) ?? protocolKind.defaultPort
        let displayName = name.isEmpty ? host : name
        let decodedRemotePath = decodeFileZillaRemoteDir(remoteDir)
        let cleanFolders = folderStack
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let group = cleanFolders.isEmpty ? "FileZilla" : cleanFolders.joined(separator: " / ")
        let isPassive = pasvMode.uppercased() != "MODE_ACTIVE"

        var decodedPassword: String?
        var hasPassword = false
        if !pass.isEmpty {
            hasPassword = true
            if passEncoding == "base64" {
                if let data = Data(base64Encoded: pass),
                   let str = String(data: data, encoding: .utf8),
                   !str.isEmpty {
                    decodedPassword = str
                }
            } else if passEncoding != "crypt" {
                decodedPassword = pass
            }
        }

        // Never store decoded passwords inside ServerProfile.
        let profile = ServerProfile(
            name: displayName,
            group: group,
            host: host,
            port: resolvedPort,
            username: user,
            protocolKind: protocolKind,
            initialPath: decodedRemotePath,
            defaultLocalPath: localDir,
            ftpPassiveMode: isPassive
        )

        items.append(ImportedServerItem(
            sourceFormat: "FileZilla XML",
            profile: profile,
            hasPassword: hasPassword,
            optionalPassword: decodedPassword,
            selected: true
        ))
    }

    private func decodeFileZillaRemoteDir(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        if trimmed.hasPrefix("/") {
            return RemotePath.normalize(trimmed)
        }
        // FileZilla encodes RemoteDir as "<type> <prefixLen> [<prefix>] (<segLen> <segName>)*"
        var index = trimmed.startIndex
        func nextToken() -> String? {
            while index < trimmed.endIndex && trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            guard index < trimmed.endIndex else { return nil }
            let start = index
            while index < trimmed.endIndex && !trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            return String(trimmed[start..<index])
        }
        func readLengthPrefixedSegment(length: Int) -> String? {
            while index < trimmed.endIndex && trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            guard length > 0, let end = trimmed.index(index, offsetBy: length, limitedBy: trimmed.endIndex) else {
                return nil
            }
            let seg = String(trimmed[index..<end])
            index = end
            return seg
        }

        guard nextToken() != nil,
              let prefixLenStr = nextToken(),
              let prefixLen = Int(prefixLenStr) else {
            return RemotePath.normalize("/" + trimmed)
        }
        if prefixLen > 0 {
            _ = readLengthPrefixedSegment(length: prefixLen)
        }

        var parts: [String] = []
        while let segLenStr = nextToken(), let segLen = Int(segLenStr) {
            guard let seg = readLengthPrefixedSegment(length: segLen) else { break }
            parts.append(seg)
        }
        if parts.isEmpty {
            return "/"
        }
        return RemotePath.normalize("/" + parts.joined(separator: "/"))
    }
}
