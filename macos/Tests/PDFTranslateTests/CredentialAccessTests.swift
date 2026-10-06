import CoreGraphics
import Foundation
import XCTest
@testable import PDFTranslate

private enum CredentialFixtureError: Error { case denied, unexpectedSynchronousCall }

/// No Security framework calls. Explicit reads remain suspended until the test
/// releases them, even if their caller cancels, as a system authorization may do.
private final class ControlledCredentialStore: AsyncCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var requests: [String] = []
    private var pending: [Int: CheckedContinuation<String?, Error>] = [:]
    private var passiveReads = 0
    private var synchronousCalls = 0
    private var writes = 0
    private var deletes = 0
    private var rejectWrites = false

    init(account: String, key: String) { values = [account: key] }
    var authorizedReadCount: Int { lock.withLock { requests.count } }
    var passiveReadCount: Int { lock.withLock { passiveReads } }
    var synchronousCallCount: Int { lock.withLock { synchronousCalls } }
    var writeCount: Int { lock.withLock { writes } }
    var deleteCount: Int { lock.withLock { deletes } }
    func value(for account: String) -> String? { lock.withLock { values[account] } }
    func denyWrites() { lock.withLock { rejectWrites = true } }

    func read(account: String) throws -> String? { try unexpectedSynchronousCall() }
    func write(_ key: String, account: String) throws { let _: String? = try unexpectedSynchronousCall() }
    func delete(account: String) throws { let _: String? = try unexpectedSynchronousCall() }
    private func unexpectedSynchronousCall() throws -> String? {
        lock.withLock { synchronousCalls += 1 }
        throw CredentialFixtureError.unexpectedSynchronousCall
    }

    func read(account: String, allowAuthentication: Bool) async throws -> String? {
        guard allowAuthentication else {
            lock.withLock { passiveReads += 1 }
            throw CredentialAccessError.authorizationRequired
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                let index = requests.count
                requests.append(account)
                pending[index] = continuation
            }
        }
    }

    func writeAsync(_ key: String, account: String) async throws {
        try lock.withLock {
            if rejectWrites { throw CredentialFixtureError.denied }
            values[account] = key; writes += 1
        }
    }

    func deleteAsync(account: String) async throws {
        try lock.withLock {
            if rejectWrites { throw CredentialFixtureError.denied }
            values.removeValue(forKey: account); deletes += 1
        }
    }

    func finishRead(_ index: Int = 0, with result: Result<String?, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: index) }
        continuation?.resume(with: result)
    }

    func releaseAll() {
        let remaining = lock.withLock {
            let result = Array(pending.values)
            pending.removeAll()
            return result
        }
        for continuation in remaining { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class CredentialAccessTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let store: ControlledCredentialStore
        var account: String { ServiceConfiguration().credentialAccount }
    }

    func testStartupAndPassiveSettingsLoadNeverAuthorizeOrMutateCredentials() async throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.store.authorizedReadCount, 0)
        XCTAssertEqual(fixture.store.passiveReadCount, 0)
        XCTAssertEqual(fixture.store.synchronousCallCount, 0)
        XCTAssertThrowsError(try fixture.model.storedKey(for: fixture.model.preferences.provider))
        do {
            _ = try await fixture.model.loadAPIKey(for: fixture.model.preferences.provider)
            XCTFail("An uncached passive load must request explicit authorization")
        } catch CredentialAccessError.authorizationRequired { }
        catch { XCTFail("Unexpected passive load error: \(error)") }
        XCTAssertEqual(fixture.store.passiveReadCount, 1)
        XCTAssertEqual(fixture.store.authorizedReadCount, 0)
        XCTAssertEqual(fixture.store.synchronousCallCount, 0)
        XCTAssertEqual(fixture.store.writeCount, 0)
        XCTAssertEqual(fixture.store.deleteCount, 0)
        XCTAssertEqual(fixture.store.value(for: fixture.account), "existing-fixture-key")
    }

    func testSavingPreferencesWithNilKeyPreservesAnUnreadableSavedKey() async throws {
        let fixture = try makeFixture()
        _ = try? await fixture.model.loadAPIKey(for: fixture.model.preferences.provider)
        var changed = fixture.model.preferences
        changed.provider.model = "edited-model"
        changed.target = "ja"
        try await fixture.model.applySettings(changed, apiKey: nil)
        XCTAssertEqual(fixture.model.preferences, changed)
        XCTAssertEqual(fixture.store.value(for: fixture.account), "existing-fixture-key")
        XCTAssertEqual(fixture.store.writeCount, 0)
        XCTAssertEqual(fixture.store.deleteCount, 0)
        XCTAssertEqual(fixture.store.authorizedReadCount, 0)
        let persisted = try String(contentsOf: fixture.root.appendingPathComponent("application/preferences.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("existing-fixture-key"))
        XCTAssertFalse(persisted.contains("api_key"))
    }

    func testBlankSaveCannotDeleteAnUnreadKeyOrOneWhoseExplicitReadFailed() async throws {
        let fixture = try makeFixture()
        let original = fixture.model.preferences
        var changed = original
        changed.provider.model = "not-yet-saved"
        await expectProtectedDeletion(fixture.model, preferences: changed)
        let read = Task { try await fixture.model.loadAPIKey(for: original.provider, allowAuthentication: true) }
        try await eventually { fixture.store.authorizedReadCount == 1 }
        fixture.store.finishRead(with: .failure(CredentialFixtureError.denied))
        do { _ = try await read.value; XCTFail("The explicit read should fail") }
        catch CredentialFixtureError.denied { }
        catch { XCTFail("Unexpected read error: \(error)") }
        await expectProtectedDeletion(fixture.model, preferences: changed)
        XCTAssertEqual(fixture.model.preferences, original)
        XCTAssertEqual(fixture.store.value(for: fixture.account), "existing-fixture-key")
        XCTAssertEqual(fixture.store.deleteCount, 0)
        XCTAssertEqual(fixture.store.writeCount, 0)
    }

    func testExplicitReadYieldsMainActorThenCachesWithoutAnotherAuthorization() async throws {
        let fixture = try makeFixture()
        let config = fixture.model.preferences.provider
        let read = Task { try await fixture.model.loadAPIKey(for: config, allowAuthentication: true) }
        try await eventually { fixture.store.authorizedReadCount == 1 }
        // The read is still suspended. Main-actor UI work must remain runnable.
        let heartbeat = Task { @MainActor in
            fixture.model.presentLinkImport()
            return fixture.model.linkImportPresented
        }
        let responded = await heartbeat.value
        XCTAssertTrue(responded)
        XCTAssertFalse(fixture.model.hasAPIKey)
        XCTAssertEqual(fixture.store.synchronousCallCount, 0)
        fixture.store.finishRead(with: .success("existing-fixture-key"))
        let key = try await read.value
        XCTAssertEqual(key, "existing-fixture-key")
        XCTAssertTrue(fixture.model.hasAPIKey)
        let cached = try await fixture.model.loadAPIKey(for: config)
        XCTAssertEqual(cached, key)
        XCTAssertEqual(try fixture.model.storedKey(for: config), key)
        XCTAssertEqual(fixture.store.authorizedReadCount, 1)
        XCTAssertEqual(fixture.store.passiveReadCount, 0)
        XCTAssertEqual(fixture.store.synchronousCallCount, 0)
    }

    func testSuccessfulReadAllowsExplicitClearWhileWriteFailurePreservesSettings() async throws {
        let fixture = try makeFixture()
        let original = fixture.model.preferences
        let read = Task { try await fixture.model.loadAPIKey(for: original.provider, allowAuthentication: true) }
        try await eventually { fixture.store.authorizedReadCount == 1 }
        fixture.store.finishRead(with: .success("existing-fixture-key"))
        _ = try await read.value
        try await fixture.model.applySettings(original, apiKey: "")
        XCTAssertEqual(fixture.store.deleteCount, 1)
        XCTAssertNil(fixture.store.value(for: fixture.account))
        XCTAssertFalse(fixture.model.hasAPIKey)
        try await fixture.model.applySettings(original, apiKey: "replacement-fixture-key")
        fixture.store.denyWrites()
        var changed = original
        changed.provider.model = "must-not-be-applied"
        do {
            try await fixture.model.applySettings(changed, apiKey: "denied-replacement")
            XCTFail("A denied write must fail without applying draft preferences")
        } catch CredentialFixtureError.denied { }
        catch { XCTFail("Unexpected write error: \(error)") }
        XCTAssertEqual(fixture.model.preferences, original)
        XCTAssertEqual(fixture.store.value(for: fixture.account), "replacement-fixture-key")
        XCTAssertEqual(try fixture.model.storedKey(for: original.provider), "replacement-fixture-key")
        XCTAssertTrue(fixture.model.hasAPIKey)
    }

    func testLateReadSuccessOrFailureCannotReplaceAnExplicitlySavedKey() async throws {
        let results: [Result<String?, Error>] = [.success("stale-fixture-key"), .failure(CredentialFixtureError.denied)]
        for result in results {
            let fixture = try makeFixture()
            let config = fixture.model.preferences.provider
            let read = Task { try await fixture.model.loadAPIKey(for: config, allowAuthentication: true) }
            try await eventually { fixture.store.authorizedReadCount == 1 }
            try await fixture.model.applySettings(fixture.model.preferences, apiKey: "new-fixture-key")
            fixture.store.finishRead(with: result)
            _ = try? await read.value
            let cached = try await fixture.model.loadAPIKey(for: config)
            XCTAssertEqual(cached, "new-fixture-key")
            XCTAssertEqual(fixture.store.value(for: fixture.account), "new-fixture-key")
            XCTAssertTrue(fixture.model.hasAPIKey)
            XCTAssertEqual(fixture.store.writeCount, 1)
            XCTAssertEqual(fixture.store.deleteCount, 0)
        }
    }

    func testCancelledReadDoesNotCacheItsLateResultOrPermitDeletion() async throws {
        let fixture = try makeFixture()
        let read = Task { try await fixture.model.loadAPIKey(for: fixture.model.preferences.provider, allowAuthentication: true) }
        try await eventually { fixture.store.authorizedReadCount == 1 }
        read.cancel()
        fixture.store.finishRead(with: .success("existing-fixture-key"))
        do { _ = try await read.value; XCTFail("Cancelled reads must reject late authorization results") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertThrowsError(try fixture.model.storedKey(for: fixture.model.preferences.provider))
        XCTAssertFalse(fixture.model.hasAPIKey)
        await expectProtectedDeletion(fixture.model, preferences: fixture.model.preferences)
        XCTAssertEqual(fixture.store.value(for: fixture.account), "existing-fixture-key")
        XCTAssertEqual(fixture.store.deleteCount, 0)
    }

    func testAsyncTranslationKeepsExplicitSelectionAndPreferenceSnapshot() async throws {
        let fixture = try makeFixture()
        let first = try job("first", in: fixture)
        let second = try job("second", in: fixture)
        fixture.model.jobs = [first, second]
        fixture.model.selection = [first.id]
        let originalOutput = fixture.model.preferences.outputPath
        fixture.model.requestTranslation()
        try await eventually { fixture.store.authorizedReadCount == 1 }
        XCTAssertEqual(fixture.model.jobs.map(\.status), [.ready, .ready])
        fixture.model.selection = [second.id]
        fixture.model.preferences.outputPath = fixture.root.appendingPathComponent("later-output").path
        fixture.model.preferences.provider.kind = "compatible"
        fixture.model.preferences.provider.baseURL = "https://example.test/v1"
        fixture.store.finishRead(with: .success("existing-fixture-key"))
        try await eventually { fixture.model.jobs[0].status == .queued }
        XCTAssertEqual(fixture.model.jobs[1].status, .ready)
        XCTAssertEqual(fixture.model.jobs[0].outputDirectory.path, originalOutput)
        XCTAssertEqual(fixture.model.jobs[0].providerName, "DeepSeek")
        XCTAssertEqual(fixture.model.selection, [second.id])
        XCTAssertFalse(fixture.model.running)
    }

    func testQuitDoesNotWaitForAuthorizationOrQueueItsLateResult() async throws {
        let fixture = try makeFixture()
        let paper = try job("paper", in: fixture)
        fixture.model.jobs = [paper]; fixture.model.selection = [paper.id]
        fixture.model.requestTranslation()
        try await eventually { fixture.store.authorizedReadCount == 1 }
        var stopped = false
        fixture.model.afterStop = { stopped = true }
        fixture.model.prepareToQuit()
        XCTAssertTrue(stopped, "Quitting must not wait on a system authorization dialog")
        fixture.store.finishRead(with: .success("existing-fixture-key"))
        // Let the resumed main-actor continuation drain; it must ignore queued work.
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fixture.model.jobs[0].status, .ready)
        XCTAssertFalse(fixture.model.running)
        XCTAssertEqual(fixture.model.waitingCount, 0)
        XCTAssertFalse(fixture.model.settingsRequested)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rumi-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ControlledCredentialStore(account: ServiceConfiguration().credentialAccount, key: "existing-fixture-key")
        let command = RuntimeCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], directory: root, developmentRoot: nil)
        let model = AppModel(storage: root.appendingPathComponent("application"), credentials: store, runtimeCommand: command)
        model.preferences.outputPath = root.appendingPathComponent("outputs").path
        model.checking = true // Inspect the queue without ever launching an engine.
        addTeardownBlock {
            await MainActor.run { model.prepareToQuit(); store.releaseAll() }
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, model: model, store: store)
    }

    private func job(_ name: String, in fixture: Fixture) throws -> TranslationJob {
        let url = fixture.root.appendingPathComponent(name + ".pdf")
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return TranslationJob(input: url, outputDirectory: fixture.root)
    }

    private func expectProtectedDeletion(_ model: AppModel, preferences: AppPreferences) async {
        do { try await model.applySettings(preferences, apiKey: ""); XCTFail("An unread or failed key must not be deleted") }
        catch CredentialAccessError.unreadableKeyCannotBeDeleted { }
        catch { XCTFail("Unexpected deletion error: \(error)") }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "CredentialAccessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Credential operation did not reach the expected state"])
    }
}
