import Security
import XCTest
@testable import Pulso

final class SharedKeychainTests: XCTestCase {
    func testClaudeLogoutAndAccountChangeRejectLateCookieRenewal() throws {
        let memory = Memory()
        let vault = ClaudeCredentialVault(keychain: memory.item)
        let original = ClaudeWebCredentials(sessionKey: "sk-ant-original",
                                           organizationID: "01531D14-44AB-4DBB-9D96-02CFD19C7712", expiresAt: nil)
        let renewed = ClaudeWebCredentials(sessionKey: "sk-ant-renewed", organizationID: original.organizationID, expiresAt: nil)
        try vault.save(original)
        try vault.replace(renewed, matching: original)
        XCTAssertEqual(try vault.load(), renewed)
        XCTAssertThrowsError(try vault.replace(original, matching: original))
        XCTAssertEqual(try vault.load(), renewed)
        try vault.delete()
        XCTAssertThrowsError(try vault.replace(renewed, matching: renewed))
        XCTAssertNil(try vault.load())
    }

    func testMigrationVerifiesSharedCopyBeforeRemovingLegacyCredential() throws {
        let memory = Memory()
        memory.items["legacy"] = Data("fixture-secret".utf8)
        XCTAssertEqual(try memory.item.load(), Data("fixture-secret".utf8))
        XCTAssertNil(memory.items["legacy"])
        XCTAssertEqual(memory.items["shared"], Data("fixture-secret".utf8))
        XCTAssertEqual(memory.accessibility as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testFailedMigrationKeepsOriginalCredential() {
        let memory = Memory()
        memory.items["legacy"] = Data("fixture-secret".utf8)
        memory.writeStatus = errSecNotAvailable
        XCTAssertThrowsError(try memory.item.load())
        XCTAssertEqual(memory.items["legacy"], Data("fixture-secret".utf8))
        XCTAssertNil(memory.items["shared"])
    }

    func testFailedVerificationDoesNotDeleteOriginalCredential() {
        let memory = Memory()
        memory.items["legacy"] = Data("fixture-secret".utf8)
        memory.corruptRead = true
        XCTAssertThrowsError(try memory.item.load())
        XCTAssertEqual(memory.items["legacy"], Data("fixture-secret".utf8))
    }

    func testUnavailableSharedKeychainDoesNotFallBackToLegacy() {
        let memory = Memory()
        memory.items["legacy"] = Data("fixture-secret".utf8)
        memory.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try memory.item.load())
        XCTAssertEqual(memory.readGroups, ["shared"])
        XCTAssertNotNil(memory.items["legacy"])
    }

    func testLogoutDeletesBothCopiesWithoutResurrectingLegacySession() throws {
        let memory = Memory()
        memory.items = ["legacy": Data("old".utf8), "shared": Data("new".utf8)]
        try memory.item.delete()
        XCTAssertNil(try memory.item.load())
        XCTAssertTrue(memory.items.isEmpty)
    }

    func testWidgetCannotMigrateAppPrivateCredentials() throws {
        let memory = Memory()
        memory.items["legacy"] = Data("fixture-secret".utf8)
        var item = memory.item
        item.legacyGroup = nil
        XCTAssertNil(try item.load())
        XCTAssertEqual(memory.readGroups, ["shared"])
        XCTAssertNotNil(memory.items["legacy"])
    }

    func testAppAndWidgetShipMatchingExpandedKeychainGroups() throws {
        let group = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "PulsoKeychainGroup") as? String)
        XCTAssertFalse(group.contains("$("))
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("PulsoWidgets.appex")))
        XCTAssertEqual(widget.object(forInfoDictionaryKey: "PulsoKeychainGroup") as? String, group)
        XCTAssertNil(widget.object(forInfoDictionaryKey: "PulsoLegacyKeychainGroup"))
        XCTAssertNotEqual(Bundle.main.object(forInfoDictionaryKey: "PulsoLegacyKeychainGroup") as? String, group)
    }

    private final class Memory {
        var items: [String: Data] = [:]
        var writeStatus = errSecSuccess
        var readStatus = errSecSuccess
        var corruptRead = false
        var accessibility: Any?
        var readGroups: [String] = []

        var item: SharedKeychain {
            SharedKeychain(service: "fixture.service", account: "fixture", group: "shared", legacyGroup: "legacy",
                           operations: .init(read: { [self] query in
                let group = query[kSecAttrAccessGroup as String] as! String
                readGroups.append(group)
                guard readStatus == errSecSuccess else { return (readStatus, nil) }
                guard let data = items[group] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, corruptRead && group == "shared" ? Data("incorrect-copy".utf8) : data)
            }, add: { [self] attributes in
                guard writeStatus == errSecSuccess else { return writeStatus }
                let group = attributes[kSecAttrAccessGroup as String] as! String
                guard items[group] == nil else { return errSecDuplicateItem }
                items[group] = attributes[kSecValueData as String] as? Data
                accessibility = attributes[kSecAttrAccessible as String]
                return errSecSuccess
            }, update: { [self] query, attributes in
                guard writeStatus == errSecSuccess else { return writeStatus }
                let group = query[kSecAttrAccessGroup as String] as! String
                guard items[group] != nil else { return errSecItemNotFound }
                items[group] = attributes[kSecValueData as String] as? Data
                accessibility = attributes[kSecAttrAccessible as String]
                return errSecSuccess
            }, delete: { [self] query in
                let group = query[kSecAttrAccessGroup as String] as! String
                return items.removeValue(forKey: group) == nil ? errSecItemNotFound : errSecSuccess
            }))
        }
    }
}
