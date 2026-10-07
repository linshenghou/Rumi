import CoreGraphics
import CryptoKit
import Foundation
import XCTest
@testable import PDFTranslate

private final class IntegrationCredentials: CredentialStoring {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func write(_ key: String, account: String) throws { values[account] = key }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

@MainActor
final class AppModelIntegrationTests: XCTestCase {
    private struct Trace: Decodable {
        var phase: String
        var operation: String
        var input: String?
        var output: String?
        var model: String?
        var keyHash: String?
    }

    private struct Fixture {
        var root: URL
        var model: AppModel
        var credentials: IntegrationCredentials
        func release(_ input: String) throws {
            try Data().write(to: root.appendingPathComponent(input + ".release"))
        }
        func started(_ input: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(input + ".started").path)
        }
        func trace() throws -> [Trace] {
            let url = root.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try Data(contentsOf: url).split(separator: 0x0A).map { try JSONDecoder().decode(Trace.self, from: Data($0)) }
        }
    }

    func testOnlyExplicitDocumentsTranslateSequentiallyAndSelectedResultOpens() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let first = try job("first", in: fixture)
        let untouched = try job("not-selected", in: fixture)
        let second = try job("second", in: fixture)
        model.jobs = [first, untouched, second]
        model.selection = [first.id]
        model.requestTranslation()
        try await eventually("first document reports real progress") { model.jobs[0].progress == 42 }
        XCTAssertEqual(model.jobs[0].status, .running)
        XCTAssertEqual(model.jobs[1].status, .ready)
        XCTAssertEqual(model.jobs[2].status, .ready)
        XCTAssertEqual(model.variant, .original)
        model.requestTranslation([second.id])
        XCTAssertEqual(model.jobs[2].status, .queued)
        XCTAssertFalse(fixture.started("second"))
        try fixture.release("first")
        try await eventually("selected result opens and second starts") { model.jobs[0].status == .completed && model.jobs[2].progress == 42 }
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertEqual(model.variant, .translated)
        XCTAssertEqual(model.jobs[0].progress, 100)
        XCTAssertNotNil(model.jobs[0].mono)
        XCTAssertNotNil(model.jobs[0].dual)
        try fixture.release("second")
        try await eventually("queue drains after both helpers exit") { !model.hasWork }
        XCTAssertEqual(model.jobs.map(\.status), [.completed, .ready, .completed])
        XCTAssertEqual(model.selection, [first.id])
        XCTAssertEqual(model.variant, .translated)
        XCTAssertFalse(fixture.started("not-selected"))
        let trace = try fixture.trace().filter { $0.operation == "translate" }
        XCTAssertEqual(trace.map { "\($0.phase):\($0.input ?? "")" }, ["begin:first", "exit:first", "begin:second", "exit:second"])
        for output in model.jobs[0].outputs.values { XCTAssertTrue(FileManager.default.fileExists(atPath: output)) }
    }

    func testPausedQueueKeepsProviderKeyAndOutputSnapshotAcrossSettingsChanges() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let first = try job("first", in: fixture)
        let second = try job("second", in: fixture)
        model.jobs = [first, second]; model.selection = [first.id, second.id]
        let initialRoot = model.preferences.outputPath
        model.requestTranslation()
        try await eventually("first job starts") { model.jobs[0].progress == 42 }
        model.toggleQueuePause()
        var changed = model.preferences
        changed.provider.model = "fixture-new-model"
        changed.outputPath = fixture.root.appendingPathComponent("new-output-root").path
        try model.apply(changed, apiKey: "replacement-fixture-key")
        try fixture.release("first")
        try await eventually("pause leaves second job queued") { !model.running && model.waitingCount == 1 }
        XCTAssertTrue(model.paused)
        XCTAssertFalse(fixture.started("second"))
        model.toggleQueuePause()
        try await eventually("resume launches second job") { model.jobs[1].progress == 42 }
        let request = try XCTUnwrap(fixture.trace().first { $0.phase == "begin" && $0.input == "second" })
        XCTAssertEqual(request.model, "fixture-original-model")
        XCTAssertEqual(request.keyHash, digest("original-fixture-key"))
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(request.output)).deletingLastPathComponent().path, initialRoot)
        XCTAssertFalse(try String(contentsOf: fixture.root.appendingPathComponent("application/jobs.json"), encoding: .utf8).contains("original-fixture-key"))
        try fixture.release("second")
        try await eventually("resumed queue completes") { !model.hasWork }
        XCTAssertEqual(model.jobs.map(\.status), [.completed, .completed])
    }

    func testFailedAndCancelledRetriesRetainPreviousSuccessfulOutputs() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        var failing = try job("fail", in: fixture)
        var cancelling = try job("cancel", in: fixture)
        let previous = try paper("previous-success.pdf", in: fixture.root)
        let originalData = try Data(contentsOf: previous)
        for index in 0..<2 {
            if index == 0 { failing.status = .completed; failing.outputs = ["mono_pdf_path": previous.path]; failing.lastVariant = .translated }
            else { cancelling.status = .completed; cancelling.outputs = ["mono_pdf_path": previous.path]; cancelling.lastVariant = .translated }
        }
        model.jobs = [failing, cancelling]; model.selection = [failing.id]
        XCTAssertEqual(model.variant, .translated)
        model.requestTranslation()
        try await eventually("retry switches to original while running") { model.jobs[0].progress == 42 }
        XCTAssertEqual(model.variant, .original)
        try fixture.release("fail")
        try await eventually("failed retry exits") { !model.running }
        XCTAssertEqual(model.jobs[0].status, .failed)
        XCTAssertEqual(model.jobs[0].error, L10n.text("Could not connect to the translation service. Check your connection and endpoint."))
        XCTAssertEqual(model.jobs[0].mono, previous)
        model.selection = [cancelling.id]
        model.requestTranslation()
        try await eventually("second retry starts") { model.jobs[1].progress == 42 }
        model.cancel(cancelling.id)
        try await eventually("cancelled helper exits") { !model.running }
        XCTAssertEqual(model.jobs[1].status, .cancelled)
        XCTAssertNil(model.jobs[1].error)
        XCTAssertEqual(model.jobs[1].mono, previous)
        XCTAssertEqual(try Data(contentsOf: previous), originalData)
    }

    func testBackgroundCompletionDoesNotStealAnotherDocumentsSelectionOrVariant() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let translating = try job("background", in: fixture)
        var reading = try job("reading", in: fixture)
        let bilingual = try paper("reading-dual.pdf", in: fixture.root)
        reading.status = .completed; reading.outputs = ["dual_pdf_path": bilingual.path]
        reading.lastVariant = .bilingual
        model.jobs = [translating, reading]; model.selection = [translating.id]
        model.requestTranslation()
        try await eventually("background job starts") { model.jobs[0].progress == 42 }
        model.selection = [reading.id]
        XCTAssertEqual(model.variant, .bilingual)
        try fixture.release("background")
        try await eventually("background job finishes") { !model.running }
        XCTAssertEqual(model.jobs[0].status, .completed)
        XCTAssertEqual(model.selection, [reading.id])
        XCTAssertEqual(model.variant, .bilingual)
        XCTAssertEqual(model.selectedJob?.dual, bilingual)
    }

    func testRuntimeFailureKeepsQueueUnstartedAndExplicitRetryRecovers() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let failureFlag = fixture.root.appendingPathComponent("check-fails")
        try Data().write(to: failureFlag)
        let document = try job("retry", in: fixture)
        model.jobs = [document]; model.selection = [document.id]
        model.requestTranslation()
        try await eventually("runtime check fails") { !model.checking }
        XCTAssertFalse(model.engineReady)
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.jobs[0].status, .queued)
        XCTAssertFalse(fixture.started("retry"))
        try FileManager.default.removeItem(at: failureFlag)
        model.checkEngine()
        try await eventually("retry check starts previously queued task") { model.jobs[0].progress == 42 }
        XCTAssertTrue(model.engineReady)
        try fixture.release("retry")
        try await eventually("recovered queue completes") { !model.hasWork }
        XCTAssertEqual(model.jobs[0].status, .completed)
    }

    func testInjectedServiceOperationsUseProtocolAndImportRemainsExplicit() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        model.testService(model.preferences.provider, key: "connection-fixture-key")
        try await eventually("connection result arrives") { !model.serviceBusy }
        XCTAssertEqual(model.serviceMessage, L10n.text("Connected. You can start translating."))
        var imported: ProviderRequest?
        let saved = model.preferences
        model.importLegacyConfig(path: "/fixture/selected-config.toml") { imported = $0 }
        try await eventually("explicit import result arrives") { !model.serviceBusy }
        XCTAssertEqual(imported?.apiKey, "import-fixture-key")
        XCTAssertEqual(imported?.thinkingMode, "enabled")
        XCTAssertEqual(imported?.reasoningEffort, "max")
        XCTAssertEqual(model.preferences, saved)
        XCTAssertEqual(try model.storedKey(for: saved.provider), "original-fixture-key")
        let events = try fixture.trace()
        XCTAssertEqual(events.filter { $0.phase == "begin" }.map(\.operation), ["test_connection", "import_config"])
        XCTAssertFalse(model.checking); XCTAssertFalse(model.running)
    }

    func testIncompatibleOrMissingProtocolKeepsQueueAndRecoversAfterRepair() async throws {
        for ready in [#"{"type":"ready","protocol_version":1}"#,
                      #"{"type":"ready","protocol_version":3}"#,
                      #"{"type":"ready"}"#] {
            let fixture = try makeFixture()
            let model = fixture.model
            let events = fixture.root.appendingPathComponent("check-events.json")
            try Data("[\(ready)]".utf8).write(to: events)
            let document = try job("retry", in: fixture)
            model.jobs = [document]; model.selection = [document.id]
            model.requestTranslation()
            try await eventually("incompatible check exits") { !model.checking }
            XCTAssertFalse(model.engineReady)
            XCTAssertFalse(fixture.started("retry"))
            XCTAssertEqual(model.jobs[0].status, .queued)
            XCTAssertEqual(model.notice, L10n.text("This translation component is incompatible with Rumi. Reinstall the app, then check again."))
            try FileManager.default.removeItem(at: events)
            model.checkEngine()
            try await eventually("compatible component resumes queue") { model.jobs[0].progress == 42 }
            XCTAssertNil(model.notice)
            try fixture.release("retry")
            try await eventually("repaired translation completes") { !model.hasWork }
            XCTAssertEqual(model.jobs[0].status, .completed)
        }
    }

    func testReadyCannotLaunchTranslationBeforeSuccessfulCheckExit() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let wait = fixture.root.appendingPathComponent("check-wait")
        try Data().write(to: wait)
        try Data().write(to: fixture.root.appendingPathComponent("check-fails"))
        model.checkEngine()
        try await eventually("ready is consumed while helper remains alive") {
            // The error follows ready on the same pipe, proving both were delivered.
            model.notice == "Fixture check is still running"
        }
        XCTAssertTrue(model.checking)
        XCTAssertFalse(model.engineReady)
        let document = try job("during-check", in: fixture)
        model.jobs = [document]; model.selection = [document.id]
        model.requestTranslation()
        XCTAssertFalse(model.running)
        XCTAssertEqual(model.jobs[0].status, .queued)
        try FileManager.default.removeItem(at: wait)
        try await eventually("failed check exits") { !model.checking }
        XCTAssertFalse(model.engineReady)
        XCTAssertFalse(fixture.started("during-check"))
    }

    func testCheckErrorCannotBeOverriddenByReadyAndZeroExit() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        try Data(#"[{"type":"error","code":"engine"},{"type":"ready","protocol_version":2}]"#.utf8)
            .write(to: fixture.root.appendingPathComponent("check-events.json"))
        let document = try job("check-error", in: fixture)
        model.jobs = [document]; model.selection = [document.id]
        model.requestTranslation()
        try await eventually("contradictory check exits") { !model.checking }
        XCTAssertFalse(model.engineReady)
        XCTAssertEqual(model.jobs[0].status, .queued)
        XCTAssertFalse(fixture.started("check-error"))
        XCTAssertEqual(model.notice, L10n.text("The translation engine or its resources are missing or damaged. Reinstall the app."))
    }

    func testSuccessfulEngineCheckDoesNotDismissHistoryWarning() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let warning = L10n.text("History could not be read. The original file has been preserved and will not be overwritten.")
        model.notice = warning
        model.checkEngine()
        XCTAssertEqual(model.notice, warning)
        try await eventually("successful check exits") { !model.checking }
        XCTAssertTrue(model.engineReady)
        XCTAssertEqual(model.notice, warning)
    }

    func testIncompleteOrUnreadableFinishPreservesPreviousPDFsAndReadingPosition() async throws {
        for kind in ["absent", "empty", "missing", "corrupt", "incomplete"] {
            let fixture = try makeFixture()
            let model = fixture.model
            try Data(kind.utf8).write(to: fixture.root.appendingPathComponent("finish-kind"))
            var document = try job("retry", in: fixture)
            let original = try Data(contentsOf: document.input)
            let previous = try paper("previous-success.pdf", in: fixture.root)
            let previousData = try Data(contentsOf: previous)
            document.status = .completed
            document.outputs = ["mono_pdf_path": previous.path, "dual_pdf_path": previous.path]
            document.readingPositions["translated"] = ReadingPosition(pageIndex: 0, scaleFactor: 1.5, autoScales: false)
            model.jobs = [document]; model.selection = [document.id]
            model.requestTranslation()
            try await eventually("retry starts") { model.jobs[0].progress == 42 }
            try fixture.release("retry")
            try await eventually("invalid finish exits") { !model.running }
            XCTAssertEqual(model.jobs[0].status, .failed, kind)
            XCTAssertEqual(model.jobs[0].outputs, document.outputs, kind)
            XCTAssertEqual(model.jobs[0].readingPositions["translated"], document.readingPositions["translated"], kind)
            XCTAssertEqual(model.jobs[0].error, L10n.text("Translation did not produce all requested readable PDFs. Your original and previous results have been kept. Try again."))
            XCTAssertEqual(try Data(contentsOf: previous), previousData)
            XCTAssertEqual(try Data(contentsOf: document.input), original)
            model.selectVariant(.translated)
            XCTAssertEqual(model.selectedJob?.url(for: model.variant), previous)
        }
    }

    func testSingleVariantTranslationAcceptsOnlyRequestedOutput() async throws {
        for mode in ["mono", "dual"] {
            let fixture = try makeFixture()
            let model = fixture.model
            var document = try job(mode, in: fixture)
            var preferences = model.preferences
            preferences.mode = mode
            try model.apply(preferences, apiKey: "original-fixture-key")
            document.mode = mode
            model.jobs = [document]; model.selection = [document.id]
            model.requestTranslation()
            try await eventually("single variant starts") { model.jobs[0].progress == 42 }
            try fixture.release(mode)
            try await eventually("single variant completes") { !model.hasWork }
            XCTAssertEqual(model.jobs[0].status, .completed)
            XCTAssertEqual(model.jobs[0].outputs.count, 1)
            XCTAssertEqual(model.variant, mode == "mono" ? .translated : .bilingual)
        }
    }

    func testQuitCancelsActiveAndWaitingJobsBeforeAfterStop() async throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let first = try job("active", in: fixture)
        let second = try job("waiting", in: fixture)
        model.jobs = [first, second]; model.selection = [first.id, second.id]
        model.requestTranslation()
        try await eventually("active job starts") { model.jobs[0].progress == 42 }
        var stopped = false
        model.afterStop = { stopped = true }
        model.prepareToQuit()
        try await eventually("quit callback follows cancellation and process exit") { stopped }
        XCTAssertFalse(model.running)
        XCTAssertFalse(model.hasWork)
        XCTAssertEqual(model.jobs.map(\.status), [.cancelled, .cancelled])
        XCTAssertFalse(fixture.started("waiting"))
    }

    private func eventually(_ reason: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Timed out: \(reason)")
                throw NSError(domain: "FixtureTimeout", code: 1)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func job(_ name: String, in fixture: Fixture) throws -> TranslationJob {
        var job = TranslationJob(input: try paper(name + ".pdf", in: fixture.root), outputDirectory: fixture.root)
        job.pageCount = 1
        return job
    }

    private func paper(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(url: file as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return file
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PDFTranslate-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("helper.py")
        try Data(Self.helper.utf8).write(to: script)
        let command = RuntimeCommand(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path], directory: root, developmentRoot: nil)
        let credentials = IntegrationCredentials()
        let model = AppModel(storage: root.appendingPathComponent("application"), credentials: credentials, runtimeCommand: command)
        var preferences = model.preferences
        preferences.outputPath = root.appendingPathComponent("original-output-root").path
        preferences.provider.model = "fixture-original-model"
        try model.apply(preferences, apiKey: "original-fixture-key")
        addTeardownBlock {
            await MainActor.run { model.prepareToQuit() }
            for _ in 0..<100 {
                let busy = await MainActor.run { model.running || model.checking || model.serviceBusy }
                if !busy { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, model: model, credentials: credentials)
    }

    private static let helper = #"""
    import hashlib, json, os, pathlib, select, shutil, sys, time
    if os.getpgrp() != os.getpid(): os.setsid()
    root = pathlib.Path(__file__).parent
    request = json.loads(sys.stdin.readline())
    operation = request['operation']
    name = pathlib.Path(request.get('input', '')).stem
    provider = request.get('provider', {})
    def emit(value):
        print(json.dumps(value), flush=True)
    def record(phase):
        value = {'phase':phase, 'operation':operation, 'input':name,
                 'output':request.get('output'), 'model':provider.get('model'),
                 'keyHash':hashlib.sha256(provider.get('api_key','').encode()).hexdigest()}
        with (root/'events.jsonl').open('a') as output:
            output.write(json.dumps(value)+'\n')
    record('begin')
    if operation == 'check':
        events = root/'check-events.json'
        for event in (json.loads(events.read_text()) if events.exists() else [{'type':'ready','protocol_version':2}]):
            emit(event)
        if (root/'check-wait').exists():
            emit({'type':'error','message':'Fixture check is still running'})
            while (root/'check-wait').exists(): time.sleep(0.01)
        record('exit')
        sys.exit(1 if (root/'check-fails').exists() else 0)
    if operation == 'test_connection':
        emit({'type':'connection_ok','service':provider['kind'],'model':provider['model']})
        record('exit')
        sys.exit(0)
    if operation == 'import_config':
        if request.get('config_path') != '/fixture/selected-config.toml': sys.exit(1)
        emit({'type':'imported_config','provider':{'kind':'deepseek','base_url':'https://api.deepseek.com/v1',
             'model':'deepseek-v4-flash','api_key':'import-fixture-key','thinking_mode':'enabled','reasoning_effort':'max'}})
        record('exit')
        sys.exit(0)
    (root/(name+'.started')).touch()
    emit({'type':'progress_update','stage':'Translate Paragraphs','overall_progress':42})
    while not (root/(name+'.release')).exists():
        readable, _, _ = select.select([sys.stdin], [], [], 0.02)
        if readable:
            line = sys.stdin.readline()
            if not line or line.strip() == 'cancel':
                emit({'type':'cancelled'})
                record('exit')
                sys.exit(2)
    if name == 'fail':
        emit({'type':'error','code':'network','message':'Fixture network failure'})
        record('exit')
        sys.exit(1)
    output = pathlib.Path(request['output'])
    output.mkdir(parents=True, exist_ok=True)
    mono = output/'fixture-mono.pdf'
    dual = output/'fixture-dual.pdf'
    shutil.copyfile(request['input'], mono)
    shutil.copyfile(request['input'], dual)
    outputs = {}
    if request.get('mode') != 'dual': outputs['mono_pdf_path'] = str(mono)
    if request.get('mode') != 'mono': outputs['dual_pdf_path'] = str(dual)
    kind = root/'finish-kind'
    kind = kind.read_text() if kind.exists() else ''
    if kind == 'empty': outputs = {}
    elif kind == 'missing': dual.unlink()
    elif kind == 'corrupt': dual.write_text('Fixture invalid PDF')
    elif kind == 'incomplete': outputs.pop('dual_pdf_path')
    emit({'type':'finish'} if kind == 'absent' else {'type':'finish','outputs':outputs})
    # A finish event is not process exit. The queue must wait before starting next.
    time.sleep(0.05)
    record('exit')
    """#
}
