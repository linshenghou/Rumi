import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import PDFTranslate

private func arxivTestPDF(pages: Int = 2) throws -> Data {
    let data = NSMutableData()
    var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF()
    return data as Data
}

private final class ArxivProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Double?] = []
    func append(_ value: Double?) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    var values: [Double?] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// Every URL is intercepted; an unregistered request fails locally instead of
/// reaching arXiv. Unique canonical URLs keep concurrently running tests isolated.
private final class ArxivURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (ArxivURLProtocol) -> Void
    private static let lock = NSLock()
    private static var routes: [String: Handler] = [:]
    private static var sequence = 0

    static func register(_ handler: @escaping Handler) throws -> ArxivSource {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let source = try ArxivSource(String(format: "https://arxiv.org/pdf/2501.%05d", sequence))
        routes[source.url.absoluteString] = handler
        return source
    }

    static func remove(_ source: ArxivSource) {
        lock.lock(); defer { lock.unlock() }; routes.removeValue(forKey: source.url.absoluteString)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.routes[request.url?.absoluteString ?? ""]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler(self)
    }
    override func stopLoading() {}

    func respond(status: Int = 200, headers: [String: String] = [:], chunks: [Data], finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}

final class ArxivImportTests: XCTestCase {
    func testSuppliedPDFAndSupportedFormsNormalizeToCanonicalPDFURL() throws {
        let cases = [
            ("https://arxiv.org/pdf/2511.07820", "2511.07820"),
            (" \nhttps://arxiv.org/abs/2511.07820\t", "2511.07820"),
            ("https://www.arxiv.org/pdf/2511.07820v3.pdf#page=2", "2511.07820v3"),
            ("https://export.arxiv.org/abs/2511.07820v1.pdf", "2511.07820v1"),
            ("https://ARXIV.ORG:443/pdf/0704.0001", "0704.0001"),
            ("https://arxiv.org/abs/hep-th/9901001v2", "hep-th/9901001v2"),
            ("https://arxiv.org/pdf/math.GT/0309136.pdf", "math.GT/0309136")
        ]
        for (input, identifier) in cases {
            let source = try ArxivSource(input)
            XCTAssertEqual(source.identifier, identifier, input)
            XCTAssertEqual(source.url.absoluteString, "https://arxiv.org/pdf/" + identifier, input)
        }
    }

    func testUntrustedMalformedAndAmbiguousURLsAreRejected() {
        let rejected = [
            "2511.07820", "http://arxiv.org/pdf/2511.07820", "file:///pdf/2511.07820",
            "https://example.org/pdf/2511.07820", "https://arxiv.org.evil.test/pdf/2511.07820",
            "https://arxiv.org@evil.test/pdf/2511.07820", "https://name:secret@arxiv.org/pdf/2511.07820",
            "https://arxiv.org:444/pdf/2511.07820", "https://arxiv.org/pdf/2511.07820?download=1",
            "https://arxiv.org/html/2511.07820", "https://arxiv.org/pdf/../2511.07820",
            "https://arxiv.org/pdf/%32%35%31%31.07820", "https://arxiv.org/pdf/2511.07820/extra",
            "https://arxiv.org/pdf/2513.07820", "https://arxiv.org/pdf/2500.07820",
            "https://arxiv.org/pdf/2511.123", "https://arxiv.org/pdf/2511.07820v0",
            "https://arxiv.org/pdf/2511.07820v1.pdf.exe", "https://arxiv.org/pdf/2511.07820\nhttps://evil.test"
        ]
        for input in rejected {
            XCTAssertThrowsError(try ArxivSource(input), input) { error in
                XCTAssertEqual(error as? ArxivImportError, .invalidURL, input)
            }
        }
    }

    func testRedirectPolicyKeepsPaperIdentityAndExplicitVersion() throws {
        let source = try ArxivSource("https://arxiv.org/abs/2511.07820")
        for target in ["https://arxiv.org/pdf/2511.07820.pdf", "https://export.arxiv.org/pdf/2511.07820v2"] {
            XCTAssertTrue(source.permitsRedirect(to: try XCTUnwrap(URL(string: target))))
        }
        for target in ["http://arxiv.org/pdf/2511.07820", "https://evil.test/pdf/2511.07820",
                       "https://arxiv.org/abs/2511.07820", "https://arxiv.org/pdf/2511.07821",
                       "https://arxiv.org/pdf/2511.07820?token=secret"] {
            XCTAssertFalse(source.permitsRedirect(to: try XCTUnwrap(URL(string: target))), target)
        }
        let versioned = try ArxivSource("https://arxiv.org/pdf/2511.07820v2")
        XCTAssertTrue(versioned.permitsRedirect(to: URL(string: "https://www.arxiv.org/pdf/2511.07820v2.pdf")!))
        XCTAssertFalse(versioned.permitsRedirect(to: source.url))
        XCTAssertFalse(versioned.permitsRedirect(to: URL(string: "https://arxiv.org/pdf/2511.07820v3")!))
    }

    func testSuccessfulStreamCreatesReadableUniquePersistentPDFsAndProgress() async throws {
        let directory = try temporaryDirectory()
        let data = try arxivTestPDF()
        let source = try route { stub in
            XCTAssertEqual(stub.request.value(forHTTPHeaderField: "Accept"), "application/pdf")
            XCTAssertNil(stub.request.value(forHTTPHeaderField: "Authorization"))
            stub.respond(headers: ["Content-Type": "application/pdf", "Content-Length": String(data.count)],
                         chunks: [data.prefix(data.count / 2), data.suffix(data.count - data.count / 2)])
        }
        let progress = ArxivProgressLog()
        let first = try await downloader().download(source, to: directory, progress: { progress.append($0) })
        let second = try await downloader().download(source, to: directory, progress: { _ in })
        XCTAssertEqual(first.pageCount, 2)
        XCTAssertEqual(PDFDocument(url: first.url)?.pageCount, 2)
        XCTAssertEqual(try Data(contentsOf: first.url), data)
        XCTAssertNotEqual(first.url, second.url, "Repeated downloads must not overwrite an existing paper")
        let ownedDirectory = first.url.deletingLastPathComponent()
        XCTAssertNotNil(UUID(uuidString: ownedDirectory.lastPathComponent))
        XCTAssertEqual(ownedDirectory.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(first.url.lastPathComponent, source.identifier + ".pdf")
        XCTAssertEqual(first.url.pathExtension, "pdf")
        XCTAssertEqual(try contents(directory).count, 2)
        let known = progress.values.compactMap { $0 }
        XCTAssertEqual(known.first, 0)
        XCTAssertEqual(known.last, 1)
        XCTAssertTrue(zip(known, known.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    func testHTTPFailuresAndNonPDFBodiesLeaveNoPartialFiles() async throws {
        let cases: [(Int, Data, ArxivImportError)] = [
            (404, Data(), .httpStatus(404)), (429, Data(), .httpStatus(429)),
            (200, Data("<html>temporary error</html>".utf8), .invalidPDF),
            (200, Data(), .invalidPDF)
        ]
        for (status, body, expected) in cases {
            let directory = try temporaryDirectory()
            let source = try route { $0.respond(status: status, headers: ["Content-Type": "application/pdf"], chunks: [body]) }
            await expectFailure(expected) { try await self.downloader().download(source, to: directory, progress: { _ in }) }
            XCTAssertTrue(try contents(directory).isEmpty)
        }
    }

    func testBothDeclaredAndStreamedSizeLimitsCleanPartialsAndPreserveOtherFiles() async throws {
        for declaredSize in [true, false] {
            let directory = try temporaryDirectory()
            let existing = directory.appendingPathComponent("keep.pdf")
            let existingData = try arxivTestPDF(pages: 1)
            try existingData.write(to: existing)
            let source = try route { stub in
                stub.respond(headers: declaredSize ? ["Content-Length": "101"] : [:],
                             chunks: [Data(repeating: 0x41, count: 60), Data(repeating: 0x42, count: 60)])
            }
            await expectFailure(.tooLarge) { try await self.downloader(maximumBytes: 100).download(source, to: directory, progress: { _ in }) }
            XCTAssertEqual(try contents(directory).map(\.lastPathComponent), ["keep.pdf"])
            XCTAssertEqual(try Data(contentsOf: existing), existingData)
        }
    }

    func testNetworkTimeoutCleansPartialFile() async throws {
        let directory = try temporaryDirectory()
        let source = try route { stub in
            stub.respond(chunks: [Data("%PDF-1.7\npartial".utf8)], finish: false)
            stub.client?.urlProtocol(stub, didFailWithError: URLError(.timedOut))
        }
        await expectFailure(.timedOut) { try await self.downloader().download(source, to: directory, progress: { _ in }) }
        XCTAssertTrue(try contents(directory).isEmpty)
    }

    func testCancellationAfterPartialWriteReturnsCancellationAndDeletesPartial() async throws {
        let directory = try temporaryDirectory()
        let wrote = expectation(description: "first body chunk reached the downloader")
        // Cross both URLSession's small-body buffering and the downloader's 1%
        // progress threshold while keeping the response deliberately unfinished.
        let chunk = Data(repeating: 0x41, count: 128 * 1024)
        let source = try route { $0.respond(headers: ["Content-Length": "1048576"], chunks: [chunk], finish: false) }
        let operation = Task {
            try await downloader().download(source, to: directory, progress: { value in
                if let value, value > 0 { wrote.fulfill() }
            })
        }
        defer { operation.cancel() }
        await fulfillment(of: [wrote], timeout: 3)
        let owned = try XCTUnwrap(contents(directory).first)
        XCTAssertNotNil(UUID(uuidString: owned.lastPathComponent))
        let partial = try XCTUnwrap(contents(owned).first { $0.pathExtension == "part" })
        XCTAssertEqual(try Data(contentsOf: partial), chunk)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancellation should not yield a PDF") }
        catch { XCTAssertTrue(error is CancellationError, String(describing: error)) }
        XCTAssertTrue(try contents(directory).isEmpty)
    }

    private func downloader(maximumBytes: Int64 = 100 * 1024 * 1024) -> ArxivDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArxivURLProtocol.self]
        return ArxivDownloader(configuration: configuration, maximumBytes: maximumBytes)
    }

    private func route(_ handler: @escaping ArxivURLProtocol.Handler) throws -> ArxivSource {
        let source = try ArxivURLProtocol.register(handler)
        addTeardownBlock { ArxivURLProtocol.remove(source) }
        return source
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rumi-arxiv-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func contents(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func expectFailure(_ expected: ArxivImportError, operation: () async throws -> ArxivDownload) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ArxivImportError, expected) }
    }
}

private final class ArxivTestCredentials: CredentialStoring {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func write(_ key: String, account: String) throws { values[account] = key }
    func delete(account: String) throws { values.removeValue(forKey: account) }
}

/// Intentionally ignores cancellation until the test releases its continuation:
/// exercises the model's generation guard rather than relying on cooperative I/O.
private actor ControlledArxivDownloader: ArxivDownloading {
    struct Request: Sendable { let source: ArxivSource; let directory: URL }
    private var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<ArxivDownload, Error>] = [:]
    private var callbacks: [Int: @Sendable (Double?) -> Void] = [:]
    var count: Int { requests.count }

    func download(_ source: ArxivSource, to directory: URL,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> ArxivDownload {
        let index = requests.count
        requests.append(Request(source: source, directory: directory))
        callbacks[index] = progress
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func request(_ index: Int) -> Request { requests[index] }
    func report(_ value: Double?, index: Int = 0) { callbacks[index]?(value) }
    func finish(_ download: ArxivDownload, index: Int = 0) { continuations.removeValue(forKey: index)?.resume(returning: download) }
    func fail(_ error: Error, index: Int = 0) { continuations.removeValue(forKey: index)?.resume(throwing: error) }
    func releaseAll() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class ArxivModelImportTests: XCTestCase {
    private struct Fixture { let root: URL; let model: AppModel; let downloader: ControlledArxivDownloader }

    func testInvalidLinkNeverStartsDownloadOrMutatesJobs() async throws {
        let fixture = try makeFixture(hasKey: true)
        fixture.model.importArxiv("https://arxiv.org.evil.test/pdf/2511.07820")
        XCTAssertNotNil(fixture.model.linkImportError)
        XCTAssertTrue(fixture.model.linkImportPresented)
        XCTAssertFalse(fixture.model.linkImportBusy)
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        let calls = await fixture.downloader.count
        XCTAssertEqual(calls, 0)
    }

    func testDefaultImportQueuesOnlyTheDownloadedPaperAndSelectsOriginal() async throws {
        let fixture = try makeFixture(hasKey: true)
        let model = fixture.model
        let existing = TranslationJob(input: try paper(in: fixture.root, name: "already-open.pdf"), outputDirectory: fixture.root)
        model.jobs = [existing]; model.selection = [existing.id]
        model.presentLinkImport()
        model.importArxiv("https://arxiv.org/pdf/2511.07820")
        try await waitForRequest(fixture.downloader)
        await fixture.downloader.report(0.4)
        try await eventually { model.linkImportProgress == 0.4 }
        let request = await fixture.downloader.request(0)
        XCTAssertEqual(request.source.identifier, "2511.07820")
        let downloaded = try paper(in: request.directory)
        await fixture.downloader.finish(ArxivDownload(url: downloaded, pageCount: 2))
        try await eventually { !model.linkImportBusy && model.jobs.count == 2 }
        let added = try XCTUnwrap(model.jobs.first { $0.input == downloaded })
        XCTAssertEqual(added.status, .queued)
        XCTAssertEqual(added.pageCount, 2)
        XCTAssertEqual(model.jobs.first { $0.id == existing.id }?.status, .ready)
        XCTAssertEqual(model.selection, [added.id])
        XCTAssertEqual(model.variant, .original)
        XCTAssertFalse(model.linkImportPresented)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
    }

    func testDownloadOnlyNeverQueuesEvenWhenCredentialsExist() async throws {
        let fixture = try makeFixture(hasKey: true)
        fixture.model.importArxiv("https://arxiv.org/abs/2511.07820v2", translate: false)
        try await waitForRequest(fixture.downloader)
        let request = await fixture.downloader.request(0)
        let downloaded = try paper(in: request.directory)
        await fixture.downloader.finish(ArxivDownload(url: downloaded, pageCount: 2))
        try await eventually { !fixture.model.linkImportBusy && !fixture.model.jobs.isEmpty }
        XCTAssertEqual(fixture.model.jobs.map(\.status), [.ready])
        XCTAssertFalse(fixture.model.hasWork)
        XCTAssertFalse(fixture.model.settingsRequested)
    }

    func testMissingKeyKeepsImportedPaperReadyAndRequestsConfiguration() async throws {
        let fixture = try makeFixture(hasKey: false)
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07820")
        try await waitForRequest(fixture.downloader)
        let request = await fixture.downloader.request(0)
        let downloaded = try paper(in: request.directory)
        await fixture.downloader.finish(ArxivDownload(url: downloaded, pageCount: 2))
        try await eventually { !fixture.model.linkImportBusy && !fixture.model.jobs.isEmpty }
        XCTAssertEqual(fixture.model.jobs.map(\.status), [.ready])
        XCTAssertTrue(fixture.model.settingsRequested)
        XCTAssertFalse(fixture.model.hasWork)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
    }

    func testCancelledLateResultIsRemovedWithoutAddingOrQueuingJob() async throws {
        let fixture = try makeFixture(hasKey: true)
        fixture.model.presentLinkImport()
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07820")
        try await waitForRequest(fixture.downloader)
        fixture.model.cancelLinkImport()
        XCTAssertFalse(fixture.model.linkImportPresented)
        XCTAssertFalse(fixture.model.linkImportBusy)
        let request = await fixture.downloader.request(0)
        let late = try paper(in: request.directory)
        await fixture.downloader.finish(ArxivDownload(url: late, pageCount: 2))
        try await eventually { !FileManager.default.fileExists(atPath: late.path) }
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        XCTAssertFalse(fixture.model.hasWork)
        XCTAssertNil(fixture.model.linkImportError)
    }

    func testCancelledOlderDownloadCannotChangeNewImportProgressOrResult() async throws {
        let fixture = try makeFixture(hasKey: false)
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07820", translate: false)
        try await waitForRequest(fixture.downloader)
        fixture.model.cancelLinkImport()
        fixture.model.presentLinkImport()
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07821", translate: false)
        try await waitForRequest(fixture.downloader, count: 2)
        await fixture.downloader.report(0.3, index: 1)
        try await eventually { fixture.model.linkImportProgress == 0.3 }
        await fixture.downloader.report(0.9, index: 0)
        let first = await fixture.downloader.request(0)
        let stale = try paper(in: first.directory, name: "stale.pdf")
        await fixture.downloader.finish(ArxivDownload(url: stale, pageCount: 2), index: 0)
        try await eventually { !FileManager.default.fileExists(atPath: stale.path) }
        XCTAssertTrue(fixture.model.linkImportBusy)
        XCTAssertEqual(fixture.model.linkImportProgress, 0.3)
        let second = await fixture.downloader.request(1)
        let retained = try paper(in: second.directory, name: "retained.pdf")
        await fixture.downloader.finish(ArxivDownload(url: retained, pageCount: 2), index: 1)
        try await eventually { !fixture.model.linkImportBusy && fixture.model.jobs.count == 1 }
        XCTAssertEqual(fixture.model.jobs[0].input, retained)
    }

    func testDownloadErrorKeepsSheetForRetryAndQuitDiscardsLateResult() async throws {
        let fixture = try makeFixture(hasKey: true)
        fixture.model.presentLinkImport()
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07820")
        try await waitForRequest(fixture.downloader)
        await fixture.downloader.fail(ArxivImportError.httpStatus(404))
        try await eventually { !fixture.model.linkImportBusy && fixture.model.linkImportError != nil }
        XCTAssertTrue(fixture.model.linkImportPresented)
        XCTAssertTrue(fixture.model.jobs.isEmpty)
        fixture.model.presentLinkImport()
        XCTAssertNil(fixture.model.linkImportError)
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07820")
        try await waitForRequest(fixture.downloader, count: 2)
        fixture.model.prepareToQuit()
        let request = await fixture.downloader.request(1)
        let late = try paper(in: request.directory)
        await fixture.downloader.finish(ArxivDownload(url: late, pageCount: 2), index: 1)
        try await eventually { !FileManager.default.fileExists(atPath: late.path) }
        XCTAssertTrue(fixture.model.jobs.isEmpty)
    }

    func testQuitWaitsForPreviouslyCancelledDownloadCleanupBeforeCompletion() async throws {
        let fixture = try makeFixture(hasKey: false)
        fixture.model.importArxiv("https://arxiv.org/pdf/2511.07820", translate: false)
        try await waitForRequest(fixture.downloader)
        fixture.model.cancelLinkImport()
        XCTAssertFalse(fixture.model.linkImportBusy)
        XCTAssertTrue(fixture.model.needsQuitWait)
        var stopped = false
        fixture.model.afterStop = { stopped = true }
        fixture.model.prepareToQuit()
        XCTAssertFalse(stopped, "Quit must wait for a cancelled download that has not returned")
        let request = await fixture.downloader.request(0)
        let late = try paper(in: request.directory)
        await fixture.downloader.finish(ArxivDownload(url: late, pageCount: 2))
        try await eventually { stopped }
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.deletingLastPathComponent().path))
        XCTAssertFalse(fixture.model.needsQuitWait)
        XCTAssertTrue(fixture.model.jobs.isEmpty)
    }

    private func makeFixture(hasKey: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rumi-arxiv-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let downloader = ControlledArxivDownloader()
        let credentials = ArxivTestCredentials()
        // Even accidental startup cannot use the developer's real engine/API.
        let command = RuntimeCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], directory: root, developmentRoot: nil)
        let model = AppModel(storage: root.appendingPathComponent("application"), credentials: credentials,
                             runtimeCommand: command, arxivDownloader: downloader)
        var preferences = model.preferences
        preferences.outputPath = root.appendingPathComponent("outputs").path
        try model.apply(preferences, apiKey: hasKey ? "fixture-key-never-sent" : "")
        // Hold the existing translation queue before process launch so its exact
        // membership can be inspected independently from downloader completion.
        model.checking = true
        addTeardownBlock {
            await MainActor.run { model.prepareToQuit() }
            await downloader.releaseAll()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, model: model, downloader: downloader)
    }

    private func paper(in directory: URL, name: String = "downloaded.pdf") throws -> URL {
        let owned = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let url = owned.appendingPathComponent(name)
        try arxivTestPDF().write(to: url)
        return url
    }

    private func waitForRequest(_ downloader: ControlledArxivDownloader, count: Int = 1) async throws {
        for _ in 0..<200 {
            if await downloader.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ArxivImportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Downloader request was not made"])
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "ArxivImportTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Import did not reach the expected state"])
    }
}
