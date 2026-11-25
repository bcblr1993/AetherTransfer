import CoreFoundation
import Foundation

public struct S3BucketInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let creationDate: Date?

    public init(name: String, creationDate: Date? = nil) {
        self.name = name
        self.creationDate = creationDate
    }
}

public enum S3ProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case awsS3
    case awsS3IAMRole
    case cloudflareR2
    case minio
    case dreamObjects
    case wasabi
    case digitalOceanSpaces

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .awsS3:
            return L10n.tr("Amazon S3", "Amazon S3")
        case .awsS3IAMRole:
            return L10n.tr("Amazon S3 (IAM 角色 / STS)", "Amazon S3 (IAM Role / STS)")
        case .cloudflareR2:
            return L10n.tr("Cloudflare R2", "Cloudflare R2")
        case .minio:
            return L10n.tr("MinIO / 兼容 S3", "MinIO / S3-Compatible")
        case .dreamObjects:
            return L10n.tr("DreamObjects", "DreamObjects")
        case .wasabi:
            return L10n.tr("Wasabi", "Wasabi")
        case .digitalOceanSpaces:
            return L10n.tr("DigitalOcean Spaces", "DigitalOcean Spaces")
        }
    }

    public func defaultHost(region: String) -> String {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .awsS3, .awsS3IAMRole:
            return trimmed.isEmpty ? "s3.amazonaws.com" : "s3.\(trimmed).amazonaws.com"
        case .cloudflareR2:
            return "<account-id>.r2.cloudflarestorage.com"
        case .minio:
            return ""
        case .dreamObjects:
            return trimmed.isEmpty ? "objects-us-east-1.dream.io" : "objects-\(trimmed).dream.io"
        case .wasabi:
            return trimmed.isEmpty ? "s3.wasabisys.com" : "s3.\(trimmed).wasabisys.com"
        case .digitalOceanSpaces:
            return trimmed.isEmpty ? "nyc3.digitaloceanspaces.com" : "\(trimmed).digitaloceanspaces.com"
        }
    }

    public var defaultPathStyle: Bool {
        switch self {
        case .cloudflareR2, .minio:
            return true
        case .awsS3, .awsS3IAMRole, .dreamObjects, .wasabi, .digitalOceanSpaces:
            return false
        }
    }
}

public struct ImportedServerItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceFormat: String
    public var profile: ServerProfile
    public let hasPassword: Bool
    public let optionalPassword: String?
    public var selected: Bool

    public init(
        id: UUID = UUID(),
        sourceFormat: String,
        profile: ServerProfile,
        hasPassword: Bool = false,
        optionalPassword: String? = nil,
        selected: Bool = true
    ) {
        self.id = id
        self.sourceFormat = sourceFormat
        self.profile = profile
        self.hasPassword = hasPassword
        self.optionalPassword = optionalPassword
        self.selected = selected
    }
}

public struct CustomEditorMapping: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fileExtension: String
    public var appPath: String
    public var appName: String

    public init(id: UUID = UUID(), fileExtension: String, appPath: String, appName: String) {
        self.id = id
        self.fileExtension = fileExtension
        self.appPath = appPath
        self.appName = appName
    }
}

public enum TextFileEncoding: String, CaseIterable, Identifiable, Codable, Sendable {
    case utf8
    case utf16
    case isoLatin1
    case gb18030

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .utf8:
            return L10n.tr("UTF-8", "UTF-8")
        case .utf16:
            return L10n.tr("UTF-16", "UTF-16")
        case .isoLatin1:
            return L10n.tr("ISO Latin 1 (ISO-8859-1)", "ISO Latin 1 (ISO-8859-1)")
        case .gb18030:
            return L10n.tr("简体中文 (GB18030)", "Chinese Simplified (GB18030)")
        }
    }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8
        case .utf16:
            return .utf16
        case .isoLatin1:
            return .isoLatin1
        case .gb18030:
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
    }
}

public struct SyncOptions: Sendable, Equatable {
    public var timeOffsetSeconds: TimeInterval
    public var modifiedWithinSeconds: TimeInterval?
    public var followSymlinks: Bool
    public var simulateOnly: Bool

    public init(
        timeOffsetSeconds: TimeInterval = 0,
        modifiedWithinSeconds: TimeInterval? = nil,
        followSymlinks: Bool = false,
        simulateOnly: Bool = false
    ) {
        self.timeOffsetSeconds = timeOffsetSeconds
        self.modifiedWithinSeconds = modifiedWithinSeconds
        self.followSymlinks = followSymlinks
        self.simulateOnly = simulateOnly
    }
}

public struct RawCommandResult: Sendable, Equatable {
    public let command: String
    public let output: String
    public let succeeded: Bool
    public let timestamp: Date

    public init(command: String, output: String, succeeded: Bool, timestamp: Date = Date()) {
        self.command = command
        self.output = output
        self.succeeded = succeeded
        self.timestamp = timestamp
    }
}
