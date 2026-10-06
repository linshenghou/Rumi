import Foundation
import PDFKit
import Darwin

struct ArxivSource: Equatable, Sendable {
    let identifier: String
    let url: URL

    init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.port == nil || parts.port == 443,
              !parts.percentEncodedPath.contains("%") else { throw ArxivImportError.invalidURL }
        let path = parts.path
        guard path.hasPrefix("/pdf/") || path.hasPrefix("/abs/") else { throw ArxivImportError.invalidURL }
        var identifier = String(path.dropFirst(5))
        if identifier.hasSuffix(".pdf") { identifier.removeLast(4) }
        let modern = #"[0-9]{2}(?:0[1-9]|1[0-2])\.[0-9]{4,5}"#
        let legacy = #"[a-z][a-z-]*(?:\.[A-Z]{2})?/[0-9]{2}(?:0[1-9]|1[0-2])[0-9]{3}"#
        guard identifier.range(of: "^(?:\(modern)|\(legacy))(?:v[1-9][0-9]*)?$", options: .regularExpression) != nil,
              let url = URL(string: "https://arxiv.org/pdf/\(identifier)") else { throw ArxivImportError.invalidURL }
        self.identifier = identifier
        self.url = url
    }

    func permitsRedirect(to url: URL) -> Bool {
        guard url.path.hasPrefix("/pdf/"), let target = try? ArxivSource(url.absoluteString) else { return false }
        if target.identifier == identifier { return true }
        // An unversioned article may resolve to its current version, but an explicit
        // version must never silently resolve to a different paper or version.
        guard identifier.range(of: #"v[1-9][0-9]*$"#, options: .regularExpression) == nil else { return false }
        return target.identifier.replacingOccurrences(of: #"v[1-9][0-9]*$"#, with: "", options: .regularExpression) == identifier
    }
}

enum ArxivImportError: Error, LocalizedError, Equatable {
    case invalidURL, unsafeRedirect, invalidResponse, invalidPDF, tooLarge, storage, network, timedOut
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L10n.text("Paste a valid arXiv HTTPS link, such as https://arxiv.org/pdf/2511.07820.")
        case .unsafeRedirect: return L10n.text("The download redirected to an unsupported location. Check the arXiv link and try again.")
        case .invalidResponse: return L10n.text("arXiv did not return a valid download response. Try again later.")
        case .invalidPDF: return L10n.text("The downloaded file is not a readable PDF or requires a password. Check the paper link.")
        case .tooLarge: return L10n.text("This document exceeds the 100 MB download limit. Download it separately and add it from your Mac.")
        case .storage: return L10n.text("Could not save the paper. Check disk space and permissions for the app data folder.")
        case .network: return L10n.text("Could not connect to arXiv. Check your connection and try again.")
        case .timedOut: return L10n.text("The download timed out. Check your connection and try again.")
        case .httpStatus(404): return L10n.text("Paper not found on arXiv. Check that the link is complete.")
        case .httpStatus(429): return L10n.text("arXiv is limiting downloads. Try again later.")
        case .httpStatus(let status): return L10n.format("arXiv could not provide the download (HTTP %d). Try again later.", status)
        }
    }
}

struct ArxivDownload: Sendable {
    let url: URL
    let pageCount: Int

    /// Each import owns a newly created UUID directory, never a pre-existing PDF.
    func removeOwnedFiles(in directory: URL) {
        let owned = url.deletingLastPathComponent().standardizedFileURL
        guard url.isFileURL, UUID(uuidString: owned.lastPathComponent) != nil,
              owned.deletingLastPathComponent() == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: owned)
    }
}

protocol ArxivDownloading: Sendable {
    func download(_ source: ArxivSource, to directory: URL,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> ArxivDownload
}

/// Each request has an isolated session and streams straight to disk. No cookies,
/// credentials, shared cache or translation API are involved in this download.
struct ArxivDownloader: ArxivDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64

    init(configuration: URLSessionConfiguration = .ephemeral, maximumBytes: Int64 = 100 * 1024 * 1024) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.maximumBytes = maximumBytes
    }

    func download(_ source: ArxivSource, to directory: URL,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> ArxivDownload {
        let operation = ArxivDownloadOperation(source: source, directory: directory,
                                              configuration: configuration, maximumBytes: maximumBytes, progress: progress)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
        do { try Task.checkCancellation() }
        catch { result.removeOwnedFiles(in: directory); throw error }
        return result
    }
}

/// All mutable state, including cancellation and delegate callbacks, is confined
/// to this operation's serial queue. Finishing is idempotent and removes partials.
private final class ArxivDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: ArxivSource
    private let directory: URL
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64
    private let progress: @Sendable (Double?) -> Void
    private let queue = DispatchQueue(label: "org.pdfmathtranslate.next.arxiv-download")
    private var continuation: CheckedContinuation<ArxivDownload, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var partialURL: URL?
    private var ownedDirectory: URL?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var acceptedResponse = false
    private var cancelled = false
    private var finished = false
    private var redirects = 0
    private var lastProgress: Double = 0

    init(source: ArxivSource, directory: URL, configuration: URLSessionConfiguration,
         maximumBytes: Int64, progress: @escaping @Sendable (Double?) -> Void) {
        self.source = source; self.directory = directory
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.maximumBytes = maximumBytes; self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<ArxivDownload, Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let owned = self.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                // mkdir fails if the directory already exists; this request must
                // never own or clean up a previously imported paper's directory.
                guard mkdir(owned.path, 0o700) == 0 else { throw ArxivImportError.storage }
                self.ownedDirectory = owned
                let partial = owned.appendingPathComponent(".download.part")
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw ArxivImportError.storage }
                self.partialURL = partial
                self.file = try FileHandle(forWritingTo: partial)
            } catch { self.finish(.failure(ArxivImportError.storage)); return }
            self.configuration.timeoutIntervalForRequest = 30
            self.configuration.timeoutIntervalForResource = 300
            self.configuration.httpCookieStorage = nil
            self.configuration.httpShouldSetCookies = false
            self.configuration.urlCredentialStorage = nil
            self.configuration.urlCache = nil
            self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegates = OperationQueue()
            delegates.maxConcurrentOperationCount = 1
            delegates.underlyingQueue = self.queue
            let session = URLSession(configuration: self.configuration, delegate: self, delegateQueue: delegates)
            self.session = session
            var request = URLRequest(url: self.source.url)
            request.setValue("application/pdf", forHTTPHeaderField: "Accept")
            request.setValue("Rumi/\(ReleaseInfo.current.version) (macOS; paper download)", forHTTPHeaderField: "User-Agent")
            self.task = session.dataTask(with: request)
            self.progress(nil)
            self.task?.resume()
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.task?.cancel()
            if self.continuation != nil { self.finish(.failure(CancellationError())) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard !finished else { completionHandler(nil); return }
        redirects += 1
        guard redirects <= 5, let url = request.url, source.permitsRedirect(to: url) else {
            completionHandler(nil); finish(.failure(ArxivImportError.unsafeRedirect)); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, let url = http.url, source.permitsRedirect(to: url) else {
            completionHandler(.cancel); finish(.failure(ArxivImportError.invalidResponse)); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(ArxivImportError.httpStatus(http.statusCode))); return
        }
        expected = response.expectedContentLength
        guard expected <= maximumBytes else {
            completionHandler(.cancel); finish(.failure(ArxivImportError.tooLarge)); return
        }
        acceptedResponse = true
        progress(expected > 0 ? 0 : nil)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, acceptedResponse else { return }
        guard Int64(data.count) <= maximumBytes - received else { finish(.failure(ArxivImportError.tooLarge)); return }
        do { try file?.write(contentsOf: data) }
        catch { finish(.failure(ArxivImportError.storage)); return }
        received += Int64(data.count)
        if expected > 0 {
            let fraction = min(1, Double(received) / Double(expected))
            if fraction - lastProgress >= 0.01 || (fraction == 1 && lastProgress < 1) {
                lastProgress = fraction; progress(fraction)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error {
            let code = (error as? URLError)?.code
            if cancelled || code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(code == .timedOut ? ArxivImportError.timedOut : ArxivImportError.network)) }
            return
        }
        guard acceptedResponse, received > 0, let partialURL, let ownedDirectory else { finish(.failure(ArxivImportError.invalidPDF)); return }
        do { try file?.close(); file = nil }
        catch { finish(.failure(ArxivImportError.storage)); return }
        guard let document = PDFDocument(url: partialURL), !document.isLocked, document.pageCount > 0 else {
            finish(.failure(ArxivImportError.invalidPDF)); return
        }
        let filename = source.identifier.replacingOccurrences(of: "/", with: "-")
        let destination = ownedDirectory.appendingPathComponent("\(filename).pdf")
        do { try FileManager.default.moveItem(at: partialURL, to: destination) }
        catch { finish(.failure(ArxivImportError.storage)); return }
        self.partialURL = nil
        self.ownedDirectory = nil
        progress(1)
        finish(.success(ArxivDownload(url: destination, pageCount: document.pageCount)))
    }

    private func finish(_ result: Result<ArxivDownload, Error>) {
        guard !finished else { return }
        finished = true
        try? file?.close(); file = nil
        if let partialURL { try? FileManager.default.removeItem(at: partialURL) }
        partialURL = nil
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        ownedDirectory = nil
        task = nil
        session?.invalidateAndCancel(); session = nil
        continuation?.resume(with: result); continuation = nil
    }
}
