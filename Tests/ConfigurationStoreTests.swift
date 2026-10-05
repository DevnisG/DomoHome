import Foundation
import XCTest

final class MemoryCredentialStore: CredentialStore {
    var values: [String: String] = [:]
    var failInsert = false
    var failRead = false

    func read(_ reference: String) throws -> String {
        guard !failRead, let value = values[reference] else { throw ConfigurationError.invalid("Test credential failure") }
        return value
    }

    func insert(_ secret: String, reference: String) throws {
        guard !failInsert else { throw ConfigurationError.invalid("Test credential failure") }
        values[reference] = secret
    }

    func remove(_ reference: String) throws { values.removeValue(forKey: reference) }
}

final class ConfigurationStoreTests: XCTestCase {
    private var directory: URL!
    private var store: DeviceConfigurationRepository!
    private var credentials: MemoryCredentialStore!
    private var key: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DomoHomeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentials = MemoryCredentialStore()
        store = DeviceConfigurationRepository(url: directory.appendingPathComponent("data/configuration.json"), credentials: credentials)
        key = String(UUID().uuidString.prefix(16))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func lightSetup() -> LightSetup {
        LightSetup(deviceID: "test-light", ip: "192.0.2.10", displayName: "Test light", group: "Test group", localKey: key)
    }

    @objc
    func testSecretsAreNotSerialized() throws {
        try store.saveLight(lightSetup())
        let secret = UUID().uuidString
        try store.saveLock(LockSetup(clientID: "test-client", deviceID: "test-lock", clientSecret: secret))
        let data = try Data(contentsOf: store.url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(key))
        XCTAssertFalse(text.contains(secret))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil((json["lock"] as? [String: Any])?["clientSecret"])
        XCTAssertNil((json["lights"] as? [[String: Any]])?.first?["localKey"])
        XCTAssertEqual(try store.loadLights().lights[0].localKey, key)
        XCTAssertEqual(try store.loadLock().tuyaClientSecret, secret)
    }

    @objc
    func testLabelEditsDoNotRewriteCredentials() throws {
        try store.saveLight(lightSetup())
        let before = credentials.values
        try store.updateLabels([DeviceLabelUpdate(id: "test-light", displayName: "New name", group: "New group")], lockName: "")
        XCTAssertEqual(credentials.values, before)
        XCTAssertEqual(try store.document().lights[0].displayName, "New name")
        XCTAssertEqual(try store.loadLights().lights[0].localKey, key)
    }

    @objc
    func testBlankKeyPreservesExistingCredential() throws {
        try store.saveLight(lightSetup())
        let before = credentials.values
        var edit = lightSetup()
        edit.originalID = "test-light"
        edit.localKey = ""
        edit.ip = "192.0.2.11"
        try store.saveLight(edit)
        XCTAssertEqual(credentials.values, before)
        XCTAssertEqual(try store.loadLights().lights[0].ip, "192.0.2.11")
    }

    @objc
    func testRotationRetiresOldCredentialAfterCommit() throws {
        try store.saveLight(lightSetup())
        let oldReference = try store.document().lights[0].credentialReference
        var edit = lightSetup()
        edit.originalID = "test-light"
        edit.localKey = String(UUID().uuidString.prefix(16))
        try store.saveLight(edit)
        XCTAssertNil(credentials.values[oldReference])
        XCTAssertEqual(credentials.values.count, 1)
        XCTAssertEqual(try store.loadLights().lights[0].localKey, edit.localKey)
    }

    @objc
    func testKeychainFailurePreservesCurrentConfiguration() throws {
        try store.saveLight(lightSetup())
        let document = try Data(contentsOf: store.url)
        let previous = credentials.values
        credentials.failInsert = true
        var edit = lightSetup()
        edit.originalID = "test-light"
        edit.localKey = String(UUID().uuidString.prefix(16))
        XCTAssertThrowsError(try store.saveLight(edit))
        XCTAssertEqual(try Data(contentsOf: store.url), document)
        XCTAssertEqual(credentials.values, previous)
    }

    @objc
    func testReadbackFailureRollsBackNewCredential() throws {
        credentials.failRead = true
        XCTAssertThrowsError(try store.saveLight(lightSetup()))
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    @objc
    func testFileWriteFailureRollsBackNewCredential() throws {
        let blocker = directory.appendingPathComponent("blocked")
        try Data("test".utf8).write(to: blocker)
        let failing = DeviceConfigurationRepository(url: blocker.appendingPathComponent("configuration.json"), credentials: credentials)
        XCTAssertThrowsError(try failing.saveLight(lightSetup()))
        XCTAssertTrue(credentials.values.isEmpty)
    }

    @objc
    func testImportPreservesSourceAndSeparatesSecrets() throws {
        let source = directory.appendingPathComponent(".env")
        let content = """
        TUYA_SWITCH_DPID=1
        LIGHT_COUNT=1
        LIGHT_1_DEVICE_ID=test-light
        LIGHT_1_IP=192.0.2.10
        LIGHT_1_LOCAL_KEY="\(key!)"
        LIGHT_1_VERSION=3.3
        LIGHT_1_NAME='Test light'
        LIGHT_1_GROUP=Test group
        """
        let original = Data(content.utf8)
        try original.write(to: source)
        try store.importEnvironment(at: source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try store.loadLights().lights[0].localKey, key)
        XCTAssertFalse(String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains(key))
        XCTAssertThrowsError(try store.importEnvironment(at: source))
    }

    @objc
    func testValidationRejectsUnsafeInputsBeforeStoringSecrets() throws {
        for value in ["../test", "test/path", "test?query", ""] {
            var setup = lightSetup()
            setup.deviceID = value
            XCTAssertThrowsError(try store.saveLight(setup))
        }
        var setup = lightSetup()
        setup.ip = "example.invalid"
        XCTAssertThrowsError(try store.saveLight(setup))
        setup = lightSetup()
        setup.localKey = "short"
        XCTAssertThrowsError(try store.saveLight(setup))
        setup = lightSetup()
        setup.switchDPID = 0
        XCTAssertThrowsError(try store.saveLight(setup))
        XCTAssertThrowsError(try store.saveLock(LockSetup(clientID: "test-client", apiHost: "example.invalid", deviceID: "test-lock", clientSecret: "test")))
        XCTAssertTrue(credentials.values.isEmpty)
    }

    @objc
    func testSupportedRegionsRequireExactHTTPSHost() throws {
        for region in TuyaRegion.allCases {
            XCTAssertEqual(try TuyaRegion.normalizedHost(region.rawValue), region.rawValue)
            XCTAssertEqual(try TuyaRegion.normalizedHost("https://" + region.rawValue), region.rawValue)
        }
        for host in ["http://openapi.tuyaus.com", "openapi.tuyaus.com.evil.invalid", "openapi.tuyaus.com@evil.invalid", "openapi.tuyaus.com:443", "openapi.tuyaus.com/path"] {
            XCTAssertThrowsError(try TuyaRegion.normalizedHost(host))
        }
    }

    @objc
    func testUnknownSchemaAndSymlinksAreRejected() throws {
        try store.saveLight(lightSetup())
        var document = try store.document()
        document.schemaVersion = 2
        try JSONEncoder().encode(document).write(to: store.url)
        XCTAssertThrowsError(try store.document())
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.url)
        let linked = DeviceConfigurationRepository(url: link, credentials: credentials)
        XCTAssertThrowsError(try linked.document())
    }

    @objc
    func testRemovalClearsCredentialAndKeepsOtherDevices() throws {
        try store.saveLight(lightSetup())
        try store.saveLock(LockSetup(clientID: "test-client", deviceID: "test-lock", clientSecret: UUID().uuidString))
        try store.removeLight(id: "test-light")
        XCTAssertTrue(try store.document().lights.isEmpty)
        XCTAssertNotNil(try store.document().lock)
        XCTAssertEqual(credentials.values.count, 1)
        try store.removeLock()
        XCTAssertTrue(credentials.values.isEmpty)
    }

    @objc
    func testPrivateFilePermissions() throws {
        try store.saveLight(lightSetup())
        let file = try FileManager.default.attributesOfItem(atPath: store.url.path)
        let folder = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    @objc
    func testRestoreDocumentPreservesMetadataAndProtectsDestination() throws {
        try store.saveLight(lightSetup())
        let restoredURL = directory.appendingPathComponent("Documents/DomoHome/settings/configuration.json")
        let restored = DeviceConfigurationRepository(url: restoredURL, credentials: MemoryCredentialStore())
        let original = try store.document()
        try restored.restoreDocument(original)
        XCTAssertEqual(try restored.document(), original)
        let file = try FileManager.default.attributesOfItem(atPath: restoredURL.path)
        let folder = try FileManager.default.attributesOfItem(atPath: restoredURL.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try restored.restoreDocument(ConfigurationDocument())
        XCTAssertEqual(try restored.document(), original)
    }

    @objc
    func testInstalledConfigurationUsesDocumentsSettingsPath() {
        XCTAssertTrue(ConfigurationStore.url.path.hasSuffix("Documents/DomoHome/settings/configuration.json"))
    }

}
