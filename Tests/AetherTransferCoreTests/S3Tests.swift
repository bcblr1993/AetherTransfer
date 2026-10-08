import Foundation
import XCTest
@testable import AetherTransferCore

final class S3Tests: XCTestCase {
    func testFailedProfileWritePreservesOriginalEndpointAndKeychainCredentials() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-keychain-test-\(UUID())")
        let file = folder.appendingPathComponent("profiles.json"), repository = ProfileRepository(store: ProfileStore(file: file))
        var ownedCredentialID: UUID?
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if let ownedCredentialID { try? CredentialStore.remove(id: ownedCredentialID) }
            try? FileManager.default.removeItem(at: folder)
        }
        let original = ServerProfile(host: "localhost", username: "fixture")
        let saved = try await repository.save(original, credentials: Credentials(password: "test-only-first-value"), remember: true).0
        ownedCredentialID = saved.credentialID
        XCTAssertNotNil(saved.credentialID)
        XCTAssertEqual(try CredentialStore.load(profile: saved).password, "test-only-first-value")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        var changed = saved; changed.host = "different.example"
        do {
            _ = try await repository.save(changed, credentials: Credentials(password: "test-only-second-value"), remember: true)
            XCTFail("Unwritable profile directory must reject the staged save")
        } catch { }
        let reloaded = try await repository.load()
        XCTAssertEqual(reloaded, [saved])
        XCTAssertEqual(try CredentialStore.load(profile: reloaded[0]).password, "test-only-first-value")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let updated = try await repository.save(changed, credentials: Credentials(accessKey: "test-only-access", secretKey: "test-only-secret"), remember: false).0
        ownedCredentialID = updated.credentialID
        XCTAssertNotEqual(updated.credentialID, saved.credentialID)
        XCTAssertEqual(try CredentialStore.load(profile: saved).password, "")
    }
    func testConcurrentProfileImportsDoNotLoseEitherCollection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-profile-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ProfileRepository(store: ProfileStore(file: folder.appendingPathComponent("profiles.json")))
        let a = ServerProfile(host: "localhost", username: "first"), b = ServerProfile(host: "localhost", username: "second")
        let first = try JSONEncoder().encode([a]), second = try JSONEncoder().encode([b])
        async let one = repository.importing(first)
        async let two = repository.importing(second)
        _ = try await (one, two)
        let result = try await repository.load()
        XCTAssertEqual(Set(result.map(\.id)), [a.id, b.id])
    }
    func testS3BrowserPreservesRawKeysAndRejectsUnsafeLocalNames() throws {
        XCTAssertEqual(S3BrowserPath.parent("a//"), "a/")
        XCTAssertEqual(S3BrowserPath.parent("a/../"), "a/")
        XCTAssertEqual(try S3BrowserPath.append("é", to: "a/../"), "a/../é")
        XCTAssertThrowsError(try S3BrowserPath.validatePrefix("a"))
        for name in ["", ".", "..", "a/b", "a\0b"] { XCTAssertThrowsError(try S3BrowserPath.validateLocalName(name)) }
        let entries = [FileEntry(name: "é", path: "é", isDirectory: false, s3Key: "é"),
                       FileEntry(name: "e\u{301}", path: "e\u{301}", isDirectory: false, s3Key: "e\u{301}"),
                       FileEntry(name: "é", path: "é/", isDirectory: true, s3Key: "é/")]
        XCTAssertEqual(Set(entries.map(\.id)).count, 3); XCTAssertEqual(Set(entries).count, 3)
    }
    func testS3ProfileMigrationExportAndImportedTrust() throws {
        let old = ServerProfile(host: "localhost", username: "test")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        fields.removeValue(forKey: "s3Bucket"); fields.removeValue(forKey: "s3Region"); fields.removeValue(forKey: "s3CertificateAuthorityPath")
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: fields)), old)
        let profile = ServerProfile(host: "objects.example", port: 443, protocolKind: .s3, initialPath: "a/../", s3Bucket: "test-bucket", s3Region: "auto", s3CertificateAuthorityPath: "/test/authority.pem")
        try profile.validate(); XCTAssertThrowsError(try profile.url(path: profile.initialPath))
        let encoded = try JSONEncoder().encode([profile]), text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["secretKey", "accessKey", "sessionToken", "password"] { XCTAssertFalse(text.contains(forbidden)) }
        let imported = try ProfileStore.importing(encoded, into: [])
        XCTAssertNil(imported[0].s3CertificateAuthorityPath); XCTAssertEqual(imported[0].initialPath, "a/../")
        XCTAssertNotEqual(imported[0].credentialID, profile.credentialID)
        XCTAssertNil(imported[0].retiredCredentialIDs)
    }
    func testOwnedS3CleanupRecordsPersistDeduplicateAndRemainCredentialFree() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-s3-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("records.json"), store = S3CleanupStore(file: file)
        let endpoint = S3Endpoint(host: "objects.example", bucket: "test-bucket")
        let a = S3MultipartCleanup(endpoint: endpoint, key: "é", uploadID: "owned-upload")
        let b = S3MultipartCleanup(endpoint: endpoint, key: "e\u{301}", uploadID: "owned-upload")
        XCTAssertEqual(a.id, a.id); XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(Set([a, b]).count, 2)
        try await store.add(a); try await store.add(a); try await store.add(b)
        let reloaded = try await S3CleanupStore(file: file).records()
        XCTAssertEqual(reloaded.map(\.id), [a.id, b.id])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("credentials"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try await store.remove(a); let remaining = try await store.records(); XCTAssertEqual(remaining.map(\.id), [b.id])
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: file)
        do { _ = try await store.records(); XCTFail("Oversized cleanup store must reject") } catch { }
    }
    func testSignaturesMatchAllFourPublicAWSReferenceVectors() throws {
        // Public AWS documentation examples, never credentials for a real account.
        let credentials = S3Credentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let examples: [(String, String, [String], String?, String)] = [
            ("GET", "/test.txt", ["Range: bytes=0-9"], nil, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"),
            ("PUT", "/test%24file.text", ["Date: Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class: REDUCED_REDUNDANCY"], "Welcome to Amazon S3.", "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"),
            ("GET", "/?lifecycle=", [], nil, "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"),
            ("GET", "/?max-keys=2&prefix=J", [], nil, "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
        ]
        for (method, path, headers, body, expected) in examples {
            let result = try S3Signature.headers(method: method, url: "https://examplebucket.s3.amazonaws.com" + path, region: "us-east-1",
                                                 credentials: credentials, headers: headers, body: body, now: now)
            XCTAssertTrue(result.last?.hasSuffix("Signature=" + expected) == true, path)
        }
    }
    func testObjectKeysAndOpaqueTokensKeepTheirExactBytes() throws {
        let endpoint = S3Endpoint(host: "127.0.0.1", port: 9000, bucket: "fixture-bucket", secure: false)
        let key = "中文/a//.././空 格+#%?.txt"
        let raw = try endpoint.url(key: key, query: [("continuation-token", "opaque+/=%"), ("prefix", "中文/")])
        XCTAssertEqual(raw, "http://127.0.0.1:9000/fixture-bucket/%E4%B8%AD%E6%96%87/a//.././%E7%A9%BA%20%E6%A0%BC%2B%23%25%3F.txt?continuation-token=opaque%2B%2F%3D%25&prefix=%E4%B8%AD%E6%96%87%2F")
        XCTAssertNil(URLComponents(string: raw)?.user)
        XCTAssertNil(URLComponents(string: raw)?.password)
        XCTAssertThrowsError(try endpoint.url(key: String(repeating: "中", count: 342)))
        XCTAssertThrowsError(try endpoint.url(key: "unsafe\0key"))
    }
    func testEndpointTLSAndHeaderBoundaries() throws {
        for host in ["example.com", "192.168.1.1"] {
            XCTAssertThrowsError(try S3Endpoint(host: host, bucket: "fixture-bucket", secure: false).validate())
        }
        for host in ["user@example.com", "example.com/path", "example.com?x=1", "example.com\n"] {
            XCTAssertThrowsError(try S3Endpoint(host: host, bucket: "fixture-bucket").validate())
        }
        for bucket in ["ab", "Uppercase", "has space", "-leading", "trailing.", "a..b"] {
            XCTAssertThrowsError(try S3Endpoint(host: "example.com", bucket: bucket).validate())
        }
        XCTAssertThrowsError(try S3Credentials(accessKey: "access", secretKey: "secret", sessionToken: "token\r\nInjected: yes").validate())
        let profile = S3Endpoint(host: "example.com", bucket: "fixture-bucket")
        XCTAssertEqual(try JSONDecoder().decode(S3Endpoint.self, from: JSONEncoder().encode(profile)), profile)
        let record = S3MultipartCleanup(endpoint: profile, key: "file", uploadID: "owned-id")
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains("secretKey")); XCTAssertFalse(json.contains("accessKey"))
    }
    func testSigningRejectsDuplicateInjectedHeadersAndSignsSessionToken() throws {
        let credentials = S3Credentials(accessKey: "fixture", secretKey: "test-only", sessionToken: "opaque+/=")
        for headers in [["If-Match: \"version\"\r\nInjected: yes"], ["Host: different.example"],
                        ["Content-Type: first", "content-type: second"], ["Empty:   "], ["x-amz-content-sha256: wrong"]] {
            XCTAssertThrowsError(try S3Signature.headers(method: "PUT", url: "https://example.com/bucket/key", region: "us-east-1", credentials: credentials, headers: headers))
        }
        let signed = try S3Signature.headers(method: "GET", url: "https://example.com/bucket/key", region: "auto", credentials: credentials)
        XCTAssertTrue(signed.contains("x-amz-security-token: opaque+/="))
        XCTAssertTrue(signed.last?.contains(";x-amz-security-token,Signature=") == true)
        XCTAssertThrowsError(try S3Signature.headers(method: "GET", url: "https://example.com/bucket/key", region: "auto\r\nInjected", credentials: credentials))
    }
    private func page(_ children: String, truncated: Bool = false, token: String = "") -> String {
        "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Prefix></Prefix><Delimiter>/</Delimiter><EncodingType>url</EncodingType><IsTruncated>\(truncated)</IsTruncated>\(children)\(token)</ListBucketResult>"
    }
    private func object(_ key: String) -> String {
        "<Contents><Key>\(key)</Key><Size>7</Size><ETag>&quot;etag&quot;</ETag><LastModified>2026-10-07T01:02:03.123Z</LastModified></Contents>"
    }
    func testListingDistinguishesObjectAndPrefixAndKeepsOpaqueToken() throws {
        let xml = page(object("%E4%B8%AD%E6%96%87%2B%25%23") + object("same") + "<CommonPrefixes><Prefix>same/</Prefix></CommonPrefixes>",
                       truncated: true, token: "<NextContinuationToken>opaque+/=%</NextContinuationToken>")
        let result = try S3ListingPage.parse(xml, prefix: "")
        XCTAssertEqual(result.objects.map(\.key), ["中文+%#", "same", "same/"])
        XCTAssertEqual(result.objects.map(\.isPrefix), [false, false, true])
        XCTAssertEqual(result.objects[0].size, 7); XCTAssertNotNil(result.objects[0].modified)
        XCTAssertEqual(result.next, "opaque+/=%")
    }
    func testUnicodeNormalizationAndEmptyPathComponentsStayDistinct() throws {
        let result = try S3ListingPage.parse(page(object("%C3%A9") + object("e%CC%81") + "<CommonPrefixes><Prefix>/</Prefix></CommonPrefixes>"), prefix: "")
        XCTAssertEqual(result.objects.count, 3); XCTAssertEqual(Set(result.objects.map(\.id)).count, 3)
        XCTAssertEqual(Set(result.objects).count, 3); XCTAssertEqual(result.objects.last?.name, "/")
        let nested = page(object("e%CC%81/file")).replacingOccurrences(of: "<Prefix></Prefix>", with: "<Prefix>%C3%A9/</Prefix>")
        XCTAssertThrowsError(try S3ListingPage.parse(nested, prefix: "é/"))
    }
    func testListDecodesSpaceAndLiteralPlusWithoutDecodingOpaqueToken() throws {
        let xml = page(object("space+name%2B"), truncated: true, token: "<NextContinuationToken>opaque+/=%2B</NextContinuationToken>")
            .replacingOccurrences(of: "<Delimiter>/</Delimiter>", with: "<Delimiter>%2F</Delimiter>")
        let result = try S3ListingPage.parse(xml, prefix: "")
        XCTAssertEqual(result.objects.first?.key, "space name+"); XCTAssertEqual(result.next, "opaque+/=%2B")
        let nested = page(object("space+dir/child%2B")).replacingOccurrences(of: "<Prefix></Prefix>", with: "<Prefix>space+dir/</Prefix>")
        XCTAssertEqual(try S3ListingPage.parse(nested, prefix: "space dir/").objects.first?.key, "space dir/child+")
    }
    func testMalformedListingAndIncompletePaginationReject() {
        for xml in [page(object("duplicate") + object("duplicate")), page(object("child/grandchild")),
                    page(object("wrong%ZZ")), page(object("file").replacingOccurrences(of: "<Size>7</Size>", with: "<Size>-1</Size>")),
                    page(object("file").replacingOccurrences(of: "<ETag>&quot;etag&quot;</ETag>", with: "")),
                    page("", truncated: true), page("<Prefix>duplicate-field</Prefix>"),
                    page(object("file")).replacingOccurrences(of: "<EncodingType>url</EncodingType>", with: ""),
                    page(object("file")).replacingOccurrences(of: "http://s3.amazonaws.com/doc/2006-03-01/", with: "https://other.invalid/")] {
            XCTAssertThrowsError(try S3ListingPage.parse(xml, prefix: ""), xml)
        }
        XCTAssertThrowsError(try S3ListingPage.parse(page(object("file")), prefix: "other/"))
        XCTAssertThrowsError(try S3ListingPage.parse(page(object("file")), prefix: "", bucket: "different-bucket"))
    }
    func testXMLRejectsEntitiesDeepNestingAndHTTP200ErrorBody() {
        XCTAssertThrowsError(try S3XML.parse("<!DOCTYPE root [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><root>&secret;</root>", root: "root"))
        XCTAssertThrowsError(try S3XML.parse(String(repeating: "<root>", count: 25) + String(repeating: "</root>", count: 25), root: "root"))
        XCTAssertThrowsError(try S3XML.parse("<Error><Code>InvalidPart</Code></Error>", root: "CompleteMultipartUploadResult"))
        XCTAssertThrowsError(try S3XML.parse("<root>\(String(repeating: "x", count: 16 * 1024 + 1))</root>", root: "root"))
        XCTAssertThrowsError(try S3XML.parse("<root>", root: "root"))
    }
}
