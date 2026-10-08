import Foundation

public enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case password, privateKey, agent
    public var title: String {
        switch self {
        case .password: L10n.text("密码")
        case .privateKey: L10n.text("私钥文件")
        case .agent: "SSH agent"
        }
    }
    var nativeValue: Int32 {
        switch self { case .password: 0; case .privateKey: 1; case .agent: 2 }
    }
}

public enum SSHAuthenticationError: Error, LocalizedError, Sendable {
    case privateKeyRequired, agentUnavailable, configuration
    public var errorDescription: String? {
        switch self {
        case .privateKeyRequired: L10n.text("请选择 SSH 私钥文件。")
        case .agentUnavailable: L10n.text("未找到可用的 SSH agent 环境；请启动 agent 并加载密钥，或选择其他认证方式。")
        case .configuration: L10n.text("无法配置 SSH 认证方式。")
        }
    }
}

extension Credentials {
    /// Keep only the selected mechanism's secret material, including in memory.
    public func forProfile(_ profile: ServerProfile) -> Self {
        if profile.protocolKind == .s3 {
            return Self(accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken)
        }
        if profile.protocolKind == .sftp {
            switch profile.effectiveSSHAuthentication {
            case .agent: return Self()
            case .privateKey: return Self(passphrase: passphrase)
            case .password: return Self(password: password)
            }
        }
        return Self(password: password)
    }
    public func needsPrompt(for profile: ServerProfile) -> Bool {
        if profile.protocolKind == .s3 { return accessKey.isEmpty || secretKey.isEmpty }
        if profile.protocolKind == .sftp && profile.effectiveSSHAuthentication != .password { return false }
        return password.isEmpty
    }
}
