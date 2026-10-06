import AppKit
import CoreGraphics
import XCTest
@testable import PDFTranslate

private final class MemoryCredentialStore: CredentialStoring {
    var values: [String: String] = [:]
    var writeFailure: Error?
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    func read(account: String) throws -> String? { values[account] }
    func write(_ key: String, account: String) throws {
        if let writeFailure { throw writeFailure }
        writeCount += 1
        values[account] = key
    }
    func delete(account: String) throws {
        if let writeFailure { throw writeFailure }
        deleteCount += 1
        values.removeValue(forKey: account)
    }
}

final class DesktopTests: XCTestCase {
    private func storage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFTranslate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func paper(in directory: URL, name: String = "论文.pdf", pages: Int = 3) throws -> URL {
        let file = directory.appendingPathComponent(name)
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: file as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return file
    }

    func testPipeEventsSplitAcrossUTF8BoundariesAndLogLines() throws {
        let text = "ignored log\n{\"type\":\"progress_update\",\"stage\":\"翻译正文\",\"overall_progress\":42.5}\n{\"type\":\"finish\",\"outputs\":{\"mono_pdf_path\":\"/example/译文.pdf\"}}\n"
        var decoder = EventDecoder()
        var events: [BridgeEvent] = []
        for byte in text.utf8 { events += decoder.append(Data([byte])) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].stage, "翻译正文")
        XCTAssertEqual(events[0].overallProgress, 42.5)
        XCTAssertEqual(events[1].outputs?["mono_pdf_path"], "/example/译文.pdf")
    }

    func testConnectionSuccessUsesActualBridgeShape() {
        var decoder = EventDecoder()
        let events = decoder.append(Data(#"{"type":"connection_ok","service":"deepseek","model":"deepseek-chat"}"#.utf8) + Data([0x0A]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, "connection_ok")
        XCTAssertNil(events.first?.provider)
    }

    func testDecoderRecoversFromOversizedNonProtocolOutput() {
        var decoder = EventDecoder()
        XCTAssertTrue(decoder.append(Data(repeating: 0x78, count: 1_048_577)).isEmpty)
        let events = decoder.append(Data("{\"type\":\"ready\",\"protocol_version\":2}\n".utf8))
        XCTAssertEqual(events.map(\.type), ["ready"])
    }

    func testFolderInputsDeduplicateSymlinksAndRejectOtherFormats() throws {
        let directory = try storage()
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let pdf = try paper(in: nested, name: "Paper.PDF")
        let alias = directory.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pdf)
        let other = directory.appendingPathComponent("report.txt")
        try Data().write(to: other)
        let result = InputCollector.collect([directory, pdf, alias, other, directory.appendingPathComponent("missing.pdf")])
        XCTAssertEqual(result.files, [pdf])
        XCTAssertEqual(result.rejected, 2)
    }

    @MainActor
    func testLegacyMigrationNeverRestartsWorkAndKeepsOutputs() throws {
        let directory = try storage()
        let input = try paper(in: directory)
        let output = try paper(in: directory, name: "译文.pdf")
        var running = TranslationJob(input: input, outputDirectory: directory)
        running.status = .running
        var queued = TranslationJob(input: input, outputDirectory: directory)
        queued.status = .queued
        var finished = TranslationJob(input: input, outputDirectory: directory)
        finished.status = .completed; finished.outputs = ["mono_pdf_path": output.path]
        let legacy = try JSONEncoder().encode([running, queued, finished])
        try legacy.write(to: directory.appendingPathComponent("jobs.json"))
        try Data(#"{"source":"de","target":"en","configPath":"/example/old-config.toml","autoStart":true,"pythonPath":"/old/python"}"#.utf8)
            .write(to: directory.appendingPathComponent("preferences.json"))
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        XCTAssertEqual(model.jobs.map(\.status), [.cancelled, .ready, .completed])
        XCTAssertFalse(model.running); XCTAssertFalse(model.checking); XCTAssertFalse(model.engineReady)
        XCTAssertEqual(model.preferences.source, "de")
        XCTAssertEqual(model.preferences.legacyConfigPath, "/example/old-config.toml")
        XCTAssertEqual(model.jobs[2].mono, output)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("jobs.json.v1.backup")), legacy)
        model.save()
        let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: directory.appendingPathComponent("jobs.json")))
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(archive.jobs.map(\.status), [.cancelled, .ready, .completed])
        model.clearFinished()
        XCTAssertEqual(model.jobs.map(\.status), [.ready])
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testCorruptStorageIsNotOverwritten() throws {
        let directory = try storage()
        let data = Data("this is not JSON".utf8)
        for name in ["jobs.json", "preferences.json"] { try data.write(to: directory.appendingPathComponent(name)) }
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        XCTAssertNotNil(model.notice)
        model.save()
        for name in ["jobs.json", "preferences.json"] { XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), data) }
    }

    @MainActor
    func testFutureHistoryVersionIsNotOverwritten() throws {
        let directory = try storage()
        let data = Data(#"{"version":999,"jobs":[]}"#.utf8)
        try data.write(to: directory.appendingPathComponent("jobs.json"))
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        model.save()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("jobs.json")), data)
    }

    @MainActor
    func testFuturePreferencesVersionIsNotOverwritten() throws {
        let directory = try storage()
        let data = Data(#"{"version":999,"source":"ja","futureSettings":{"feature":true}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("preferences.json"))
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        model.save()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("preferences.json")), data)
    }

    @MainActor
    func testAPIKeyOnlyUsesCredentialStoreAndCanBeDeleted() throws {
        let directory = try storage()
        let credentials = MemoryCredentialStore()
        let model = AppModel(storage: directory, credentials: credentials)
        var preferences = model.preferences
        preferences.provider.model = "deepseek-v4-flash"
        try model.apply(preferences, apiKey: "  private-secret-key  ")
        XCTAssertTrue(model.hasAPIKey)
        XCTAssertEqual(try model.storedKey(for: preferences.provider), "private-secret-key")
        for name in ["preferences.json", "jobs.json"] {
            let contents = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(contents.contains("private-secret-key"))
            XCTAssertFalse(contents.contains("api_key"))
        }
        try model.apply(preferences, apiKey: "")
        XCTAssertFalse(model.hasAPIKey)
        XCTAssertNil(credentials.values[preferences.provider.credentialAccount])
    }

    @MainActor
    func testCredentialFailureDoesNotApplyUnsavedPreferences() throws {
        let credentials = MemoryCredentialStore()
        let model = AppModel(storage: try storage(), credentials: credentials)
        let original = model.preferences
        var changed = original; changed.provider.model = "new-model"
        credentials.writeFailure = NSError(domain: "Keychain", code: -1)
        XCTAssertThrowsError(try model.apply(changed, apiKey: "secret"))
        XCTAssertEqual(model.preferences, original)
        XCTAssertFalse(model.hasAPIKey)
    }

    @MainActor
    func testImportedConfigRemainsDraftUntilExplicitSave() throws {
        let directory = try storage()
        let credentials = MemoryCredentialStore()
        let model = AppModel(storage: directory, credentials: credentials)
        let eventData = Data(#"{"type":"imported_config","provider":{"kind":"deepseek","base_url":"https://api.deepseek.com/v1","model":"deepseek-v4-flash","api_key":"imported-secret","thinking_mode":"enabled","reasoning_effort":"max"}}"#.utf8)
        let event = try JSONDecoder().decode(BridgeEvent.self, from: eventData)
        let imported = try XCTUnwrap(event.provider)
        var draft = model.preferences; draft.provider = imported.configuration
        XCTAssertEqual(draft.provider.model, "deepseek-flash")
        XCTAssertEqual(model.preferences.provider.model, "deepseek-flash")
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertEqual(credentials.writeCount, 0)
        XCTAssertEqual(credentials.deleteCount, 0)
        let encodedDraft = try String(decoding: JSONEncoder().encode(draft), as: UTF8.self)
        XCTAssertFalse(encodedDraft.contains("imported-secret"))
        try model.apply(draft, apiKey: imported.apiKey)
        XCTAssertEqual(model.preferences.provider.thinkingMode, "enabled")
        XCTAssertEqual(model.preferences.provider.reasoningEffort, "max")
        XCTAssertEqual(try model.storedKey(for: draft.provider), "imported-secret")
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("preferences.json"), encoding: .utf8).contains("imported-secret"))
    }

    @MainActor
    func testSavedDeepSeekAliasesNormalizeWithoutCredentialWritesOrStartingWork() throws {
        let cases: [(kind: String, model: String, thinking: String, expectedModel: String, expectedThinking: String)] = [
            ("deepseek", "", "disabled", "deepseek-flash", "disabled"),
            ("deepseek", "  ", "", "deepseek-flash", ""),
            ("deepseek", "deepseek-chat", "", "deepseek-flash", "disabled"),
            ("deepseek", "deepseek-reasoner", "", "deepseek-flash", "enabled"),
            ("deepseek", "deepseek-v4-flash", "", "deepseek-flash", ""),
            ("deepseek", "deepseek-chat", "enabled", "deepseek-flash", "enabled"),
            ("deepseek", "deepseek-reasoner", "disabled", "deepseek-flash", "disabled"),
            ("deepseek", "deepseek-v4-pro", "enabled", "deepseek-v4-pro", "enabled"),
            ("compatible", "deepseek-chat", "", "deepseek-chat", ""),
            ("compatible", " custom-model ", "enabled", " custom-model ", "enabled"),
        ]
        for item in cases {
            let directory = try storage()
            let credentials = MemoryCredentialStore()
            var saved = AppPreferences()
            saved.provider = ServiceConfiguration(kind: item.kind, baseURL: "https://custom.example/v1", model: item.model,
                                                  thinkingMode: item.thinking, reasoningEffort: "high")
            credentials.values[saved.provider.credentialAccount] = "existing-credential"
            let data = try JSONEncoder().encode(saved)
            let path = directory.appendingPathComponent("preferences.json")
            try data.write(to: path)
            let model = AppModel(storage: directory, credentials: credentials)
            XCTAssertEqual(model.preferences.provider.model, item.expectedModel, item.model)
            XCTAssertEqual(model.preferences.provider.thinkingMode, item.expectedThinking, item.model)
            XCTAssertEqual(model.preferences.provider.reasoningEffort, "high")
            XCTAssertEqual(model.preferences.provider.credentialAccount, saved.provider.credentialAccount)
            XCTAssertEqual(try model.storedKey(for: model.preferences.provider), "existing-credential")
            XCTAssertEqual(credentials.writeCount, 0); XCTAssertEqual(credentials.deleteCount, 0)
            XCTAssertEqual(try Data(contentsOf: path), data, "Opening preferences must not rewrite the source file")
            XCTAssertFalse(model.checking); XCTAssertFalse(model.serviceBusy); XCTAssertFalse(model.running)
        }
    }

    func testOlderPreferencesWithMissingModelOrThinkingUseCurrentModelAndPriorIntent() throws {
        let missingModel = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"version":2,"provider":{"kind":"deepseek"}}"#.utf8))
        XCTAssertEqual(missingModel.provider.model, "deepseek-flash")
        let reasoner = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"version":2,"provider":{"kind":"deepseek","model":"deepseek-reasoner"}}"#.utf8))
        XCTAssertEqual(reasoner.provider.model, "deepseek-flash")
        XCTAssertEqual(reasoner.provider.thinkingMode, "enabled")
    }

    @MainActor
    func testImportedLegacyModelsNormalizeDraftOnlyAndPreserveKeyAndThinking() throws {
        let credentials = MemoryCredentialStore()
        let model = AppModel(storage: try storage(), credentials: credentials)
        let before = model.preferences
        let cases: [(kind: String, model: String, mode: String?, expectedModel: String, expectedMode: String)] = [
            ("deepseek", "deepseek-chat", nil, "deepseek-flash", "disabled"),
            ("deepseek", "deepseek-reasoner", "", "deepseek-flash", "enabled"),
            ("deepseek", "deepseek-reasoner", "disabled", "deepseek-flash", "disabled"),
            ("deepseek", "deepseek-v4-flash", "enabled", "deepseek-flash", "enabled"),
            ("deepseek", "", "", "deepseek-flash", ""),
            ("deepseek", "deepseek-v4-pro", "enabled", "deepseek-v4-pro", "enabled"),
            ("compatible", "deepseek-reasoner", nil, "deepseek-reasoner", ""),
        ]
        for item in cases {
            let provider = ProviderRequest(kind: item.kind, baseURL: "https://custom.example/v1", model: item.model,
                                           apiKey: "imported-key", thinkingMode: item.mode, reasoningEffort: "max")
            var draft = model.preferences
            draft.provider = provider.configuration
            XCTAssertEqual(draft.provider.model, item.expectedModel)
            XCTAssertEqual(draft.provider.thinkingMode, item.expectedMode)
            XCTAssertEqual(draft.provider.reasoningEffort, "max")
            XCTAssertEqual(provider.apiKey, "imported-key")
            XCTAssertFalse(try String(decoding: JSONEncoder().encode(draft), as: UTF8.self).contains("imported-key"))
        }
        XCTAssertEqual(model.preferences, before)
        XCTAssertEqual(credentials.writeCount, 0); XCTAssertEqual(credentials.deleteCount, 0)
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertFalse(model.checking); XCTAssertFalse(model.serviceBusy); XCTAssertFalse(model.running)
    }

    @MainActor
    func testMissingKeyKeepsDocumentReadyAndRequestsSettings() throws {
        let directory = try storage()
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        let job = TranslationJob(input: try paper(in: directory), outputDirectory: directory)
        model.jobs = [job]; model.selection = [job.id]
        model.requestTranslation()
        XCTAssertEqual(model.jobs[0].status, .ready)
        XCTAssertTrue(model.settingsRequested)
        XCTAssertFalse(model.checking); XCTAssertFalse(model.running)
    }

    @MainActor
    func testQueuedOptionsStayFrozenAndCancellationDoesNotDeleteFiles() throws {
        let directory = try storage()
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        try model.apply(model.preferences, apiKey: "queue-only-secret")
        var job = TranslationJob(input: try paper(in: directory), outputDirectory: directory, source: "en", target: "zh-CN", pages: "1-2", mode: "both")
        job.pageCount = 3
        model.jobs = [job]; model.selection = [job.id]
        // Simulate the runtime check in progress so no helper/API is launched.
        model.checking = true
        model.requestTranslation()
        XCTAssertEqual(model.jobs[0].status, .queued)
        model.updateOptions(id: job.id, source: "fr", target: "de", pages: "3", mode: "mono")
        XCTAssertEqual(model.jobs[0].source, "en"); XCTAssertEqual(model.jobs[0].target, "zh-CN")
        XCTAssertEqual(model.jobs[0].pages, "1-2"); XCTAssertEqual(model.jobs[0].mode, "both")
        model.remove([job.id]); XCTAssertEqual(model.jobs.count, 1)
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("jobs.json"), encoding: .utf8).contains("queue-only-secret"))
        model.cancel(job.id)
        XCTAssertEqual(model.jobs[0].status, .cancelled)
        XCTAssertFalse(model.hasWork)
        model.remove([job.id]); XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.input.path))
    }

    @MainActor
    func testQueuedOutputLocationIsCapturedWhenUserStartsTranslation() throws {
        let directory = try storage()
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        let chosenOutput = directory.appendingPathComponent("chosen-at-start")
        var preferences = model.preferences; preferences.outputPath = chosenOutput.path
        try model.apply(preferences, apiKey: "secret")
        let job = TranslationJob(input: try paper(in: directory), outputDirectory: directory.appendingPathComponent("old-import-location"))
        model.jobs = [job]; model.selection = [job.id]; model.checking = true
        model.requestTranslation()
        preferences.outputPath = directory.appendingPathComponent("later-settings-change").path
        try model.apply(preferences, apiKey: "replacement-key")
        XCTAssertEqual(model.jobs[0].outputDirectory.standardizedFileURL, chosenOutput.standardizedFileURL)
        model.cancel(job.id)
    }

    @MainActor
    func testBatchValidationDoesNotPartiallyQueueDocuments() throws {
        let directory = try storage()
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        try model.apply(model.preferences, apiKey: "secret")
        var good = TranslationJob(input: try paper(in: directory), outputDirectory: directory)
        good.pageCount = 3
        var bad = TranslationJob(input: good.input, outputDirectory: directory, pages: "8")
        bad.pageCount = 3
        model.jobs = [good, bad]; model.selection = [good.id, bad.id]
        model.checking = true
        model.requestTranslation()
        XCTAssertEqual(model.jobs.map(\.status), [.ready, .ready])
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testReadingPositionsAndVariantSurviveRestart() throws {
        let directory = try storage()
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        let input = try paper(in: directory)
        let output = try paper(in: directory, name: "译文.pdf")
        var job = TranslationJob(input: input, outputDirectory: directory)
        job.status = .completed; job.outputs = ["mono_pdf_path": output.path]
        model.jobs = [job]; model.selection = [job.id]
        model.selectVariant(.translated)
        let position = ReadingPosition(pageIndex: 2, scaleFactor: 1.4, autoScales: false)
        model.remember(position, id: job.id, variant: .translated)
        model.save()
        let restored = AppModel(storage: directory, credentials: MemoryCredentialStore())
        XCTAssertEqual(restored.variant, .translated)
        XCTAssertEqual(restored.selectedJob?.readingPositions["translated"], position)
        XCTAssertEqual(restored.selectedJob?.mono, output)
    }

    @MainActor
    func testImportOnlyPreviewsPDFWithoutStartingTranslation() async throws {
        let directory = try storage()
        let input = try paper(in: directory)
        let model = AppModel(storage: directory, credentials: MemoryCredentialStore())
        model.add([input])
        for _ in 0..<100 where model.importing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.importing)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.pageCount, 3)
        XCTAssertEqual(model.jobs.first?.status, .ready)
        XCTAssertFalse(model.checking); XCTAssertFalse(model.running)
    }

    @MainActor
    func testPageRangesValidateBeforeAPICall() {
        for pages in ["", "1", "1-3", "1,3", "-2", "2-", " 1-2, 3 "] {
            XCTAssertNil(AppModel.pageRangeError(pages, pageCount: 3), pages)
        }
        for pages in ["0", "4", "2-1", "1,,2", "1-2-3", "-4", "1;2", "a", "-", "+1", "01"] {
            XCTAssertNotNil(AppModel.pageRangeError(pages, pageCount: 3), pages)
        }
    }

    func testCustomServiceAddressesRejectPlaintextAndEmbeddedCredentials() {
        for address in ["http://example.com/v1", "https://key:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/#key", "not-a-url"] {
            let provider = ServiceConfiguration(kind: "compatible", baseURL: address, model: "model")
            XCTAssertNotNil(provider.validationError, address)
        }
        for address in ["https://example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:8000/v1"] {
            let provider = ServiceConfiguration(kind: "compatible", baseURL: address, model: "model")
            XCTAssertNil(provider.validationError, address)
        }
        let deepSeek = ServiceConfiguration(kind: "deepseek", baseURL: "https://unrelated.example", model: "deepseek-chat")
        XCTAssertEqual(deepSeek.effectiveURL, "https://api.deepseek.com/v1")
    }
}
