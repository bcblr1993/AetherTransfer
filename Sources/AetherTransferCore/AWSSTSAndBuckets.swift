import Foundation
import CryptoKit

// MARK: - AWS STS Temporary Credentials & AssumeRole Client

public struct STSTemporaryCredentials: Sendable, Equatable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let sessionToken: String
    public let expiration: Date?

    public init(
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String,
        expiration: Date? = nil
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}

public struct AWSSTSClient: Sendable {
    public init() {}

    /// Calls AWS STS `AssumeRole` and returns temporary `Credentials` (`password = secretAccessKey`, `passphrase = accessKeyId`, `sessionToken = sessionToken`).
    public func assumeRole(
        profile: ServerProfile,
        credentials: Credentials,
        mfaTokenCode: String? = nil,
        sessionName: String = "AetherTransferSession",
        session: URLSession = .shared
    ) async throws -> Credentials {
        let temp = try await assumeRoleCredentials(
            profile: profile,
            credentials: credentials,
            mfaTokenCode: mfaTokenCode,
            sessionName: sessionName,
            session: session
        )
        return Credentials(
            password: temp.secretAccessKey,
            passphrase: temp.accessKeyId,
            sessionToken: temp.sessionToken
        )
    }

    /// Calls AWS STS `AssumeRole` and returns an updated ephemeral `ServerProfile` copy (`username = temporary AccessKeyId`, `s3UseSessionToken = true`) plus temporary `Credentials` without mutating permanent stored secrets.
    public func assumeRoleProfileAndCredentials(
        profile: ServerProfile,
        credentials: Credentials,
        mfaTokenCode: String? = nil,
        sessionName: String = "AetherTransferSession",
        session: URLSession = .shared
    ) async throws -> (profile: ServerProfile, credentials: Credentials, temporary: STSTemporaryCredentials) {
        let temp = try await assumeRoleCredentials(
            profile: profile,
            credentials: credentials,
            mfaTokenCode: mfaTokenCode,
            sessionName: sessionName,
            session: session
        )
        var effectiveProfile = profile
        effectiveProfile.username = temp.accessKeyId
        effectiveProfile.s3UseSessionToken = true
        let effectiveCredentials = Credentials(
            password: temp.secretAccessKey,
            passphrase: temp.accessKeyId,
            sessionToken: temp.sessionToken
        )
        return (effectiveProfile, effectiveCredentials, temp)
    }

    /// Calls AWS STS `AssumeRole` with SigV4 signing (`sts` service) and returns parsed temporary credentials.
    public func assumeRoleCredentials(
        profile: ServerProfile,
        credentials: Credentials,
        mfaTokenCode: String? = nil,
        sessionName: String = "AetherTransferSession",
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> STSTemporaryCredentials {
        try Task.checkCancellation()

        let roleARN = profile.s3IAMRoleARN.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessKeyId = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretAccessKey = credentials.password
        guard !roleARN.isEmpty, !accessKeyId.isEmpty, !secretAccessKey.isEmpty else {
            throw TransferError.invalidConnection
        }

        let region = resolvedRegion(from: profile)
        let endpointURL = try resolvedSTSEndpointURL(from: profile, region: region)
        let cleanSessionName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "AetherTransferSession"
            : sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        var params: [(String, String)] = [
            ("Action", "AssumeRole"),
            ("Version", "2011-06-15"),
            ("RoleArn", roleARN),
            ("RoleSessionName", cleanSessionName)
        ]

        let externalId = profile.s3STSExternalID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !externalId.isEmpty {
            params.append(("ExternalId", externalId))
        }

        let mfaSerial = profile.s3MFASerial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mfaSerial.isEmpty {
            let cleanToken = mfaTokenCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !cleanToken.isEmpty else {
                throw TransferError.remote(L10n.tr(
                    "需要提供 MFA 动态验证码以代入 IAM 角色。",
                    "An MFA token code is required to assume this IAM role."
                ))
            }
            params.append(("SerialNumber", mfaSerial))
            params.append(("TokenCode", cleanToken))
        }

        let formString = params
            .map { "\(S3Client.awsURIEnode($0.0, encodeSlash: true))=\(S3Client.awsURIEnode($0.1, encodeSlash: true))" }
            .joined(separator: "&")
        let body = Data(formString.utf8)

        let req = try signedSTSRequest(
            url: endpointURL,
            body: body,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: credentials.sessionToken,
            region: region,
            now: now
        )

        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let sanitized = TranscriptRedactor.sanitize(String(bodyText.prefix(240)))
            throw TransferError.remote("AWS STS AssumeRole HTTP \(status): \(sanitized)")
        }
        return try Self.parseAssumeRoleXML(data)
    }

    private func resolvedRegion(from profile: ServerProfile) -> String {
        let trimmed = profile.s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "us-east-1" : trimmed
    }

    func resolvedSTSEndpointURL(from profile: ServerProfile, region: String) throws -> URL {
        let custom = profile.s3STSEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom.isEmpty {
            guard let url = URL(string: "https://sts.\(region).amazonaws.com/") else {
                throw TransferError.invalidConnection
            }
            return url
        }
        let candidate = custom.contains("://") ? custom : "https://\(custom)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            throw TransferError.invalidConnection
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let url = components.url else {
            throw TransferError.invalidConnection
        }
        return url
    }

    func signedSTSRequest(
        url: URL,
        body: Data,
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String,
        region: String,
        now: Date = Date()
    ) throws -> URLRequest {
        guard let host = url.host, !host.isEmpty else {
            throw TransferError.invalidConnection
        }
        let hostHeader = (url.port != nil && url.port != 443 && url.port != 80) ? "\(host):\(url.port!)" : host
        let amzDate = S3Client.formatAMZDate(now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = S3Client.sha256Hex(body)
        let contentType = "application/x-www-form-urlencoded; charset=utf-8"

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(hostHeader, forHTTPHeaderField: "Host")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        var headersToSign: [String: String] = [
            "content-type": contentType,
            "host": hostHeader,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]

        let trimmedToken = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            req.setValue(trimmedToken, forHTTPHeaderField: "X-Amz-Security-Token")
            headersToSign["x-amz-security-token"] = trimmedToken
        }

        let sortedKeys = headersToSign.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(headersToSign[$0]!)\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")

        let resolvedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let canonicalURI = S3Client.canonicalURIPath(from: resolvedPath.isEmpty ? "/" : resolvedPath)
        let canonicalQuery = S3Client.canonicalQueryString(from: url)

        let canonicalRequest = [
            "POST",
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/sts/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            S3Client.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = S3Client.deriveSigningKey(secretKey: secretAccessKey, dateStamp: dateStamp, region: region, service: "sts")
        let signature = S3Client.hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authHeader = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return req
    }

    public static func parseAssumeRoleXML(_ data: Data) throws -> STSTemporaryCredentials {
        let delegate = STSAssumeRoleXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(),
              let accessKey = delegate.accessKeyId, !accessKey.isEmpty,
              let secretKey = delegate.secretAccessKey, !secretKey.isEmpty,
              let token = delegate.sessionToken, !token.isEmpty else {
            throw TransferError.invalidListing("AWS STS AssumeRole XML missing credentials")
        }
        return STSTemporaryCredentials(
            accessKeyId: accessKey,
            secretAccessKey: secretKey,
            sessionToken: token,
            expiration: delegate.expiration
        )
    }
}

private final class STSAssumeRoleXMLDelegate: NSObject, XMLParserDelegate {
    var accessKeyId: String?
    var secretAccessKey: String?
    var sessionToken: String?
    var expiration: Date?

    private var inCredentials = false
    private var currentElement = ""
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "Credentials" {
            inCredentials = true
        } else if inCredentials {
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inCredentials {
            buffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Credentials" {
            inCredentials = false
        } else if inCredentials {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "AccessKeyId":
                accessKeyId = trimmed
            case "SecretAccessKey":
                secretAccessKey = trimmed
            case "SessionToken":
                sessionToken = trimmed
            case "Expiration":
                expiration = HTTPStreamingHelper.parseHTTPDate(trimmed)
            default:
                break
            }
            buffer = ""
        }
        currentElement = ""
    }
}

// MARK: - ~/.aws/config & ~/.aws/credentials Parser

public enum AWSConfigParser {
    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    public static func defaultCredentialsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: false)
    }

    public static func parseDefaultFiles() -> [ImportedServerItem] {
        parseFiles(configURL: defaultConfigURL(), credentialsURL: defaultCredentialsURL())
    }

    public static func parseFiles(configURL: URL, credentialsURL: URL) -> [ImportedServerItem] {
        let configText = try? String(contentsOf: configURL, encoding: .utf8)
        let credentialsText = try? String(contentsOf: credentialsURL, encoding: .utf8)
        return parse(configContent: configText, credentialsContent: credentialsText)
    }

    public static func parse(configContent: String?, credentialsContent: String?) -> [ImportedServerItem] {
        var order: [String] = []
        var sections: [String: [String: String]] = [:]

        func mergeINI(_ content: String?, isConfigFile: Bool) {
            guard let content, !content.isEmpty else { return }
            var currentProfile: String?
            var skippingNonProfileSection = false

            for rawLine in content.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                    continue
                }
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !inner.isEmpty else {
                        currentProfile = nil
                        skippingNonProfileSection = true
                        continue
                    }
                    if isConfigFile {
                        if inner.lowercased() == "default" {
                            currentProfile = "default"
                            skippingNonProfileSection = false
                        } else if inner.lowercased().hasPrefix("profile ") {
                            let name = String(inner.dropFirst("profile ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            currentProfile = name.isEmpty ? nil : name
                            skippingNonProfileSection = name.isEmpty
                        } else {
                            // Ignore non-profile blocks in ~/.aws/config (e.g. [sso-session ...], [services ...])
                            currentProfile = nil
                            skippingNonProfileSection = true
                        }
                    } else {
                        currentProfile = inner
                        skippingNonProfileSection = false
                    }
                    if let name = currentProfile, sections[name] == nil {
                        order.append(name)
                        sections[name] = [:]
                    }
                    continue
                }

                guard !skippingNonProfileSection, let profileName = currentProfile else { continue }
                guard let equalsIdx = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<equalsIdx]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = String(trimmed[trimmed.index(after: equalsIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty && !value.isEmpty {
                    sections[profileName, default: [:]][key] = value
                }
            }
        }

        mergeINI(configContent, isConfigFile: true)
        mergeINI(credentialsContent, isConfigFile: false)

        var items: [ImportedServerItem] = []
        for profileName in order {
            guard let dict = sections[profileName] else { continue }

            let sourceName = dict["source_profile"]
            let sourceDict = sourceName.flatMap { sections[$0] }

            let accessKey = dict["aws_access_key_id"] ?? sourceDict?["aws_access_key_id"] ?? ""
            let secretKey = dict["aws_secret_access_key"] ?? sourceDict?["aws_secret_access_key"] ?? ""
            let sessionToken = dict["aws_session_token"] ?? sourceDict?["aws_session_token"] ?? ""
            let region = dict["region"] ?? sourceDict?["region"] ?? "us-east-1"
            let roleARN = dict["role_arn"] ?? ""
            let mfaSerial = dict["mfa_serial"] ?? ""
            let externalID = dict["external_id"] ?? ""
            let endpointURLString = dict["endpoint_url"] ?? ""

            guard !accessKey.isEmpty || !roleARN.isEmpty || !endpointURLString.isEmpty else {
                continue
            }

            var resolvedHost = region.isEmpty ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
            var resolvedPort = 443
            var pathStyle = false

            if !endpointURLString.isEmpty, let url = URL(string: endpointURLString) {
                if let h = url.host, !h.isEmpty {
                    resolvedHost = h
                    pathStyle = !h.contains("amazonaws.com")
                }
                if let p = url.port {
                    resolvedPort = p
                } else if url.scheme?.lowercased() == "http" {
                    resolvedPort = 80
                }
            }

            let effectiveSecret: String?
            if !secretKey.isEmpty {
                effectiveSecret = secretKey
            } else if !sessionToken.isEmpty {
                effectiveSecret = sessionToken
            } else {
                effectiveSecret = nil
            }

            // Never place secret keys or session tokens inside ServerProfile.
            let profile = ServerProfile(
                name: profileName == "default" ? "AWS (default)" : "AWS · \(profileName)",
                group: "AWS Config",
                host: resolvedHost,
                port: resolvedPort,
                username: accessKey,
                protocolKind: .s3,
                initialPath: "/",
                s3Bucket: "",
                s3Region: region.isEmpty ? "us-east-1" : region,
                s3PathStyle: pathStyle,
                s3UseSessionToken: !sessionToken.isEmpty || !roleARN.isEmpty,
                s3IAMRoleARN: roleARN,
                s3STSExternalID: externalID,
                s3MFASerial: mfaSerial
            )

            items.append(ImportedServerItem(
                sourceFormat: "AWS Config",
                profile: profile,
                hasPassword: effectiveSecret != nil,
                optionalPassword: effectiveSecret,
                selected: true
            ))
        }
        return items
    }
}
