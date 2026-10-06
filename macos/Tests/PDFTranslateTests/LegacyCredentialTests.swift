import Foundation
import XCTest
@testable import PDFTranslate

private final class MigrationStore: AsyncCredentialStoring, LegacyCredentialReading {
    var legacy = "legacy-fixture-key"
    var current: String?
    var legacyReads = 0
    var failImport = false
    var failSave = false
    func read(account: String) throws -> String? { throw CredentialAccessError.authorizationRequired }
    func write(_ key: String, account: String) throws { XCTFail("Unexpected synchronous write") }
    func delete(account: String) throws { XCTFail("Unexpected synchronous delete") }
    func read(account: String, allowAuthentication: Bool) async throws -> String? {
        guard allowAuthentication else { throw CredentialAccessError.authorizationRequired }
        return current
    }
    func writeAsync(_ key: String, account: String) async throws {
        if failSave { throw CredentialAccessError.authorizationRequired }
        current = key
    }
    func deleteAsync(account: String) async throws { current = nil }
    func readLegacy(account: String) async throws -> String? {
        legacyReads += 1
        if failImport { throw CredentialAccessError.authorizationRequired }
        return legacy
    }
}

@MainActor
final class LegacyCredentialTests: XCTestCase {
    private func fixture() -> (AppModel, MigrationStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = MigrationStore()
        return (AppModel(storage: root, credentials: store), store, root)
    }

    func testOnlyExplicitImportReadsLegacyAndSaveCopiesWithoutDeletion() async throws {
        let (model, store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(store.legacyReads, 0)
        _ = try? await model.loadAPIKey(for: model.preferences.provider)
        let current = try await model.loadAPIKey(for: model.preferences.provider, allowAuthentication: true)
        XCTAssertEqual(current, "")
        XCTAssertEqual(store.legacyReads, 0, "Normal loading must never fall back to the old service")
        let draft = try await model.importLegacyAPIKey(for: model.preferences.provider)
        XCTAssertEqual(draft, store.legacy)
        XCTAssertNil(store.current, "Import only prepares a settings draft")
        XCTAssertFalse(model.hasAPIKey)
        try await model.applySettings(model.preferences, apiKey: draft)
        XCTAssertEqual(store.current, "legacy-fixture-key")
        XCTAssertEqual(store.legacy, "legacy-fixture-key")
        XCTAssertTrue(model.hasAPIKey)
    }

    func testDeniedMigrationAndFailedSavePreserveBothStoresAndAllowNewKey() async throws {
        let (model, store, root) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.failImport = true
        do { _ = try await model.importLegacyAPIKey(for: model.preferences.provider); XCTFail("Expected denial") }
        catch { }
        XCTAssertNil(store.current)
        XCTAssertEqual(store.legacy, "legacy-fixture-key")
        store.failSave = true
        do { try await model.applySettings(model.preferences, apiKey: "replacement"); XCTFail("Expected failure") }
        catch { }
        XCTAssertNil(store.current)
        XCTAssertEqual(store.legacy, "legacy-fixture-key")
        store.failSave = false
        try await model.applySettings(model.preferences, apiKey: "replacement")
        XCTAssertEqual(store.current, "replacement")
        XCTAssertEqual(store.legacy, "legacy-fixture-key")
    }

    func testIndependentIdentityDoesNotReuseLegacyKeychainNamespace() {
        XCTAssertNotEqual(ReleaseInfo.current.keychainService, KeychainCredentialStore.legacyService)
        XCTAssertTrue(ReleaseInfo.current.repositoryURL.absoluteString.hasSuffix("/Rumi"))
    }
}
