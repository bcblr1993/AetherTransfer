import Foundation

/// Serializes the app's profile/Keychain writes away from the main actor.
public actor ProfileRepository {
    public static let shared = ProfileRepository()
    private let store: ProfileStore
    public init(store: ProfileStore = ProfileStore()) { self.store = store }
    public func load() throws -> [ServerProfile] { try store.load() }
    public func save(_ incoming: ServerProfile, credentials: Credentials, remember: Bool) throws -> (ServerProfile, [ServerProfile]) {
        try incoming.validate()
        if incoming.protocolKind == .s3 && remember { try credentials.s3.validate() }
        var profile = incoming, profiles = try store.load()
        let previous = profiles.first(where: { $0.id == profile.id })
        if let previous, previous.connectionIdentity != profile.connectionIdentity {
            profile.trustedHostKey = nil
            profile.sshTrustedEndpoint = nil
        }
        let stagedID = UUID(); profile.credentialID = stagedID
        let retired = Set((previous?.retiredCredentialIDs ?? []) + (previous.map { [$0.credentialID ?? $0.id] } ?? []))
        guard retired.count <= 1000 else { throw TransferError.remote(L10n.text("旧凭据清理积压过多，请先处理钥匙串错误。")) }
        profile.retiredCredentialIDs = Array(retired)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        do {
            try CredentialStore.save(credentials, profile: profile, remember: remember)
            try store.save(profiles)
        } catch {
            // Existing endpoint credentials were never changed by this attempted save.
            try? CredentialStore.remove(id: stagedID)
            throw error
        }
        var remaining: [UUID] = []
        for id in retired { do { try CredentialStore.remove(id: id) } catch { remaining.append(id) } }
        profile.retiredCredentialIDs = remaining.isEmpty ? nil : remaining
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        try store.save(profiles)
        guard remaining.isEmpty else { throw TransferError.remote(L10n.text("收藏已保存，旧凭据清理尚未完成；再次保存会重试清理。")) }
        return (profile, profiles)
    }
    public func remove(_ profile: ServerProfile) throws -> [ServerProfile] {
        var profiles = try store.load()
        guard let current = profiles.first(where: { $0.id == profile.id }) else { return profiles }
        profiles.removeAll { $0.id == profile.id }
        for id in Set((current.retiredCredentialIDs ?? []) + [current.credentialID ?? current.id]) { try CredentialStore.remove(id: id) }
        try store.save(profiles); return profiles
    }
    public func trust(_ profile: ServerProfile) throws -> [ServerProfile] {
        var profiles = try store.load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id && $0.credentialIdentity == profile.credentialIdentity }) {
            profiles[index].trustedHostKey = profile.trustedHostKey
            profiles[index].sshTrustedEndpoint = profile.sshTrustedEndpoint
            try store.save(profiles)
        }
        return profiles
    }
    public func importing(_ data: Data) throws -> [ServerProfile] {
        let profiles = try ProfileStore.importing(data, into: store.load())
        try store.save(profiles); return profiles
    }
    public func export(to url: URL) throws { try ProfileStore(file: url).save(store.load()) }
}
