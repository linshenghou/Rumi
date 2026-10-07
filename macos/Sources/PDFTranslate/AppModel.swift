import AppKit
import Combine
import Foundation
import PDFKit

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences: AppPreferences
    @Published var jobs: [TranslationJob] = []
    @Published var selection = Set<UUID>() {
        didSet {
            guard selection != oldValue else { return }
            variant = selectedJob?.lastVariant ?? .original
            if selectedJob?.url(for: variant) == nil { variant = .original }
        }
    }
    @Published var variant: DocumentVariant = .original
    @Published var engineReady = false
    @Published var checking = false
    @Published var notice: String?
    @Published var paused = false
    @Published var cancelling = false
    @Published var importing = false
    @Published var settingsRequested = false
    @Published var findRequest = UUID()
    @Published var serviceBusy = false
    @Published var serviceMessage: String?
    @Published private(set) var hasAPIKey = false
    @Published var linkImportPresented = false
    @Published private(set) var linkImportBusy = false
    @Published private(set) var linkImportProgress: Double?
    @Published private(set) var linkImportMessage: String?
    @Published private(set) var linkImportError: String?

    private var session: BackendSession?
    private var checkSession: BackendSession?
    private var engineCheckNotice: String?
    private var serviceSession: BackendSession?
    private var queuedProviders: [UUID: ProviderRequest] = [:]
    private var activeID: UUID?
    private var exiting = false
    private var started = false
    private var pendingSave: DispatchWorkItem?
    private var canSaveHistory = true
    private var canSavePreferences = true
    private var linkImportID: UUID?
    private var linkImportTasks: [UUID: Task<Void, Never>] = [:]
    private var quitCompletionSent = false
    private var credentialCache: [String: String] = [:]
    private var readableCredentialAccounts = Set<String>()
    private var credentialRevisions: [String: UUID] = [:]
    private var credentialRequestGeneration = UUID()
    var afterStop: (() -> Void)?
    private let storage: URL
    private let credentials: CredentialStoring
    private let runtimeCommand: RuntimeCommand?
    private let arxivDownloader: any ArxivDownloading

    var selectedJob: TranslationJob? { selection.count == 1 ? jobs.first { selection.contains($0.id) } : nil }
    var selectedJobs: [TranslationJob] { jobs.filter { selection.contains($0.id) } }
    var running: Bool { activeID != nil }
    var needsQuitWait: Bool { running || !linkImportTasks.isEmpty }
    var waitingCount: Int { jobs.filter { $0.status == .queued }.count }
    var hasWork: Bool { running || waitingCount > 0 }
    var eligibleSelection: [UUID] { selectedJobs.filter { !$0.status.isBusy && $0.id != activeID }.map(\.id) }

    init(storage: URL? = nil, credentials: CredentialStoring = KeychainCredentialStore(), runtimeCommand: RuntimeCommand? = nil,
         arxivDownloader: any ArxivDownloading = ArxivDownloader()) {
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PDFTranslate", isDirectory: true)
        self.credentials = credentials
        self.runtimeCommand = runtimeCommand
        self.arxivDownloader = arxivDownloader
        preferences = AppPreferences()
        let prefsURL = self.storage.appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: prefsURL) {
            if let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
                preferences = saved
                if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] == nil {
                    Self.backup(prefsURL)
                }
            } else { canSavePreferences = false; notice = L10n.text("Settings could not be read. The original file has been preserved.") }
        }
        let historyURL = self.storage.appendingPathComponent("jobs.json")
        if let data = try? Data(contentsOf: historyURL) {
            if let archive = try? JSONDecoder().decode(HistoryArchive.self, from: data), archive.version <= 2 {
                jobs = archive.jobs
            } else if let legacy = try? JSONDecoder().decode([TranslationJob].self, from: data) {
                Self.backup(historyURL); jobs = legacy
            } else { canSaveHistory = false; notice = L10n.text("History could not be read. The original file has been preserved and will not be overwritten.") }
        }
        for index in jobs.indices {
            if jobs[index].status == .running {
                jobs[index].status = .cancelled; jobs[index].stage = L10n.text("Previous translation interrupted")
            } else if jobs[index].status == .queued {
                jobs[index].status = .ready; jobs[index].stage = L10n.text("Not Translated")
            } else { jobs[index].stage = jobs[index].status.label }
            // Historical display strings may have been saved in either app language.
            if ["自定义服务", "Custom Service"].contains(jobs[index].providerName) {
                jobs[index].providerName = L10n.text("Custom Service")
            }
        }
        selection = jobs.first.map { [$0.id] } ?? []
        variant = selectedJob?.lastVariant ?? .original
        if selectedJob?.url(for: variant) == nil { variant = .original }
        refreshKeyStatus()
    }

    private static func backup(_ url: URL) {
        let backup = url.appendingPathExtension("v1.backup")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
    }

    func start() {
        guard !started else { return }
        started = true; checkEngine()
    }

    func save() {
        pendingSave?.cancel()
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            if canSavePreferences { try JSONEncoder().encode(preferences).write(to: storage.appendingPathComponent("preferences.json"), options: .atomic) }
            if canSaveHistory { try JSONEncoder().encode(HistoryArchive(jobs: jobs)).write(to: storage.appendingPathComponent("jobs.json"), options: .atomic) }
        } catch { notice = L10n.format("Could not save app data: %@", error.localizedDescription) }
    }

    func remember(_ position: ReadingPosition, id: UUID, variant: DocumentVariant) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].readingPositions[variant.rawValue] != position else { return }
        jobs[index].readingPositions[variant.rawValue] = position
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func selectVariant(_ value: DocumentVariant) {
        guard let job = selectedJob, job.url(for: value) != nil, let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        variant = value; jobs[index].lastVariant = value; save()
    }

    func storedKey(for config: ServiceConfiguration) throws -> String {
        let account = config.credentialAccount
        if credentials is any AsyncCredentialStoring {
            guard let key = credentialCache[account] else { throw CredentialAccessError.authorizationRequired }
            return key
        }
        do {
            let key = try credentials.read(account: account) ?? ""
            credentialCache[account] = key; readableCredentialAccounts.insert(account)
            return key
        } catch {
            credentialCache.removeValue(forKey: account); readableCredentialAccounts.remove(account)
            throw error
        }
    }

    func loadAPIKey(for config: ServiceConfiguration, allowAuthentication: Bool = false) async throws -> String {
        let account = config.credentialAccount
        if !allowAuthentication, let key = credentialCache[account] { return key }
        let revision = credentialRevisions[account]
        do {
            let key: String
            if let store = credentials as? any AsyncCredentialStoring {
                key = try await store.read(account: account, allowAuthentication: allowAuthentication) ?? ""
            } else { key = try storedKey(for: config) }
            try Task.checkCancellation()
            if credentialRevisions[account] == revision {
                credentialCache[account] = key; readableCredentialAccounts.insert(account)
                if preferences.provider.credentialAccount == account { hasAPIKey = !key.isEmpty }
            }
            return key
        } catch {
            if !(error is CancellationError), credentialRevisions[account] == revision {
                credentialCache.removeValue(forKey: account); readableCredentialAccounts.remove(account)
                if preferences.provider.credentialAccount == account { hasAPIKey = false }
            }
            throw error
        }
    }

    private func refreshKeyStatus() {
        // A passive refresh never asks the real Keychain to decrypt a password.
        hasAPIKey = ((try? storedKey(for: preferences.provider)) ?? "").isEmpty == false
    }

    /// Return a draft only. Saving writes to Rumi; the old entry is never deleted.
    func importLegacyAPIKey(for config: ServiceConfiguration) async throws -> String? {
        guard let store = credentials as? any LegacyCredentialReading else { return nil }
        let value = try await store.readLegacy(account: config.credentialAccount)
        try Task.checkCancellation()
        return value
    }

    func apply(_ value: AppPreferences, apiKey: String) throws {
        // This synchronous entry point is retained for in-memory stores and tests.
        // Production Keychain operations must use applySettings off the main thread.
        guard !(credentials is any AsyncCredentialStoring) else { throw CredentialAccessError.authorizationRequired }
        if let error = value.provider.validationError { throw NSError(domain: "Service", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty, !readableCredentialAccounts.contains(value.provider.credentialAccount) {
            throw CredentialAccessError.unreadableKeyCannotBeDeleted
        }
        if key.isEmpty { try credentials.delete(account: value.provider.credentialAccount) }
        else { try credentials.write(key, account: value.provider.credentialAccount) }
        credentialRevisions[value.provider.credentialAccount] = UUID()
        preferences = value; refreshKeyStatus(); save()
    }

    /// nil preserves the existing key, including when a passive read cannot be authorized.
    func applySettings(_ value: AppPreferences, apiKey: String?) async throws {
        if let error = value.provider.validationError { throw NSError(domain: "Service", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        let account = value.provider.credentialAccount
        if let apiKey {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty, !readableCredentialAccounts.contains(account) {
                throw CredentialAccessError.unreadableKeyCannotBeDeleted
            }
            if let store = credentials as? any AsyncCredentialStoring {
                if key.isEmpty { try await store.deleteAsync(account: account) }
                else { try await store.writeAsync(key, account: account) }
            } else {
                if key.isEmpty { try credentials.delete(account: account) }
                else { try credentials.write(key, account: account) }
            }
            credentialRevisions[account] = UUID()
            credentialCache[account] = key; readableCredentialAccounts.insert(account)
        }
        preferences = value; refreshKeyStatus(); save()
    }

    func testService(_ config: ServiceConfiguration, key: String) {
        if let error = config.validationError { serviceMessage = error; return }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { serviceMessage = L10n.text("Enter an API key."); return }
        runServiceRequest(BackendRequest(operation: "test_connection", provider: config.request(apiKey: key))) { [weak self] event in
            if event.type == "connection_ok" { self?.serviceMessage = L10n.text("Connected. You can start translating.") }
        }
    }

    func importLegacyConfig(path: String? = nil, _ completion: @escaping (ProviderRequest) -> Void) {
        runServiceRequest(BackendRequest(operation: "import_config", configPath: path ?? preferences.legacyConfigPath)) { [weak self] event in
            if event.type == "imported_config", let provider = event.provider {
                completion(provider); self?.serviceMessage = L10n.text("Configuration imported. Click Save to apply it.")
            }
        }
    }

    private func runServiceRequest(_ request: BackendRequest, onEvent: @escaping (BridgeEvent) -> Void) {
        guard !serviceBusy else { return }
        serviceBusy = true; serviceMessage = nil
        serviceSession = BackendSession(request: request, command: runtimeCommand, onEvent: { [weak self] event in
            if event.type == "error" { self?.serviceMessage = event.localizedMessage ?? L10n.text("Could not connect to the service.") }
            onEvent(event)
        }, onExit: { [weak self] code in
            guard let self else { return }
            self.serviceBusy = false; self.serviceSession = nil
            if self.serviceMessage == nil { self.serviceMessage = code == 0 ? L10n.text("Done.") : L10n.text("The service could not start. Try again.") }
        })
        do { try serviceSession?.start() }
        catch { serviceBusy = false; serviceSession = nil; serviceMessage = error.localizedDescription }
    }

    func checkEngine() {
        guard !checking else { return }
        checking = true; engineReady = false
        if notice == engineCheckNotice { notice = nil }
        engineCheckNotice = nil
        var receivedReady = false
        var checkFailed = false
        checkSession = BackendSession(request: BackendRequest(operation: "check"), command: runtimeCommand, onEvent: { [weak self] event in
            if event.type == "ready" {
                if event.protocolVersion == BridgeEvent.supportedProtocolVersion { receivedReady = true }
                else {
                    checkFailed = true
                    self?.reportEngineCheckFailure(L10n.text("This translation component is incompatible with Rumi. Reinstall the app, then check again."))
                }
            } else if event.type == "error" {
                checkFailed = true
                self?.reportEngineCheckFailure(event.localizedMessage)
            }
        }, onExit: { [weak self] code in
            guard let self else { return }
            self.checking = false; self.checkSession = nil
            // A ready event alone is insufficient: the check can still fail on exit.
            self.engineReady = code == 0 && receivedReady && !checkFailed
            if !self.engineReady { self.reportEngineCheckFailure(self.engineCheckNotice) }
            else { self.startNext() }
        })
        do { try checkSession?.start() }
        catch { checking = false; checkSession = nil; reportEngineCheckFailure(error.localizedDescription) }
    }

    private func reportEngineCheckFailure(_ message: String?) {
        engineCheckNotice = message ?? L10n.text("The translation engine could not start. Check it again.")
        notice = engineCheckNotice
    }

    func add(_ urls: [URL]) {
        importing = true
        let captured = preferences
        Task {
            let result = await Task.detached { () -> ([(URL, Int)], Int) in
                let collected = InputCollector.collect(urls)
                var accepted: [(URL, Int)] = []; var rejected = collected.rejected
                for file in collected.files {
                    if let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 {
                        accepted.append((file, document.pageCount))
                    } else { rejected += 1 }
                }
                return (accepted, rejected)
            }.value
            var firstID: UUID?
            for (file, pages) in result.0 {
                if let existing = jobs.first(where: { $0.input == file }) { firstID = firstID ?? existing.id; continue }
                var job = TranslationJob(input: file, outputDirectory: URL(fileURLWithPath: captured.outputPath),
                                         source: captured.source, target: captured.target, mode: captured.mode)
                job.pageCount = pages; firstID = firstID ?? job.id; jobs.append(job)
            }
            if let firstID { selection = [firstID] }
            if result.1 > 0 { notice = L10n.format("Skipped %d unsupported, unreadable, or password-protected items. Add readable PDFs.", result.1) }
            importing = false; save()
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel(); panel.title = L10n.text("Add PDF Papers")
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func presentLinkImport() {
        guard !exiting else { return }
        if !linkImportBusy {
            linkImportProgress = nil; linkImportMessage = nil; linkImportError = nil
        }
        linkImportPresented = true
    }

    func importArxiv(_ text: String, translate: Bool = true) {
        guard !exiting, !linkImportBusy else { return }
        linkImportPresented = true
        linkImportProgress = nil; linkImportMessage = nil; linkImportError = nil
        let source: ArxivSource
        do { source = try ArxivSource(text) }
        catch { linkImportError = error.localizedDescription; return }
        let id = UUID()
        let directory = storage.appendingPathComponent("Downloads", isDirectory: true)
        let captured = preferences
        linkImportID = id; linkImportBusy = true; linkImportMessage = L10n.text("Downloading from arXiv…")
        let downloader = arxivDownloader
        linkImportTasks[id] = Task { [weak self] in
            defer {
                self?.linkImportTasks.removeValue(forKey: id)
                self?.finishQuitIfPossible()
            }
            do {
                let result = try await downloader.download(source, to: directory) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.linkImportID == id, !self.exiting else { return }
                        self.linkImportProgress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
                        if self.linkImportProgress == 1 { self.linkImportMessage = L10n.text("Checking PDF…") }
                    }
                }
                guard let self, self.linkImportID == id, !self.exiting, !Task.isCancelled else {
                    result.removeOwnedFiles(in: directory)
                    return
                }
                var job = TranslationJob(input: result.url, outputDirectory: URL(fileURLWithPath: captured.outputPath),
                                         source: captured.source, target: captured.target, mode: captured.mode)
                job.pageCount = result.pageCount
                self.jobs.append(job); self.selection = [job.id]
                self.linkImportID = nil; self.linkImportBusy = false
                self.linkImportProgress = 1; self.linkImportMessage = L10n.text("Paper added.")
                self.linkImportPresented = false
                self.save()
                if translate { self.requestTranslation([job.id]) }
            } catch {
                guard let self, self.linkImportID == id, !self.exiting else { return }
                self.linkImportID = nil; self.linkImportBusy = false
                self.linkImportProgress = nil; self.linkImportMessage = nil
                if error is CancellationError { self.linkImportPresented = false }
                else { self.linkImportError = error.localizedDescription }
            }
        }
    }

    func cancelLinkImport() {
        if let id = linkImportID { linkImportTasks[id]?.cancel() }
        linkImportID = nil; linkImportBusy = false
        linkImportProgress = nil; linkImportMessage = nil; linkImportError = nil
        linkImportPresented = false
    }

    func updateOptions(id: UUID, source: String? = nil, target: String? = nil, pages: String? = nil, mode: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].status.isBusy else { return }
        if let source { jobs[index].source = source }; if let target { jobs[index].target = target }
        if let pages { jobs[index].pages = pages }; if let mode { jobs[index].mode = mode }
        save()
    }

    static func pageRangeError(_ value: String, pageCount: Int) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        for item in value.split(separator: ",", omittingEmptySubsequences: false) {
            let token = item.trimmingCharacters(in: .whitespaces)
            guard token.range(of: #"^(?:[1-9][0-9]*(?:-[1-9][0-9]*)?|-?[1-9][0-9]*|[1-9][0-9]*-)$"#, options: .regularExpression) != nil else {
                return L10n.text("Enter valid page numbers, such as 1-5,8.")
            }
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 2 else { return L10n.text("Use commas and hyphens for page ranges, such as 1-5,8.") }
            let start = parts[0].isEmpty && parts.count == 2 ? 1 : Int(parts[0])
            let end = parts.count == 1 ? start : (parts[1].isEmpty ? max(pageCount, start ?? 1) : Int(parts[1]))
            guard let start, let end, start > 0, end >= start, pageCount == 0 || end <= pageCount else {
                return pageCount > 0 ? L10n.format("Enter page numbers between 1 and %d, such as 1-5,8.", pageCount) : L10n.text("Enter valid page numbers, such as 1-5,8.")
            }
        }
        return nil
    }

    func requestTranslation(_ ids: [UUID]? = nil) {
        guard !exiting else { return }
        let requested = ids ?? eligibleSelection
        guard jobs.contains(where: { requested.contains($0.id) && !$0.status.isBusy && $0.id != activeID }) else { return }
        if let error = preferences.provider.validationError { notice = error; settingsRequested = true; return }
        let captured = preferences
        if credentials is any AsyncCredentialStoring, credentialCache[captured.provider.credentialAccount] == nil {
            let generation = credentialRequestGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    let key = try await self.loadAPIKey(for: captured.provider, allowAuthentication: true)
                    guard !self.exiting, self.credentialRequestGeneration == generation else { return }
                    self.enqueueTranslation(requested, preferences: captured, key: key)
                } catch {
                    guard !self.exiting, self.credentialRequestGeneration == generation else { return }
                    self.notice = error.localizedDescription; self.settingsRequested = true
                }
            }
            return
        }
        let key: String
        do { key = try storedKey(for: captured.provider) }
        catch { notice = error.localizedDescription; settingsRequested = true; return }
        enqueueTranslation(requested, preferences: captured, key: key)
    }

    private func enqueueTranslation(_ requested: [UUID], preferences captured: AppPreferences, key: String) {
        guard !exiting else { return }
        let indices = jobs.indices.filter { requested.contains(jobs[$0].id) && !jobs[$0].status.isBusy && jobs[$0].id != activeID }
        guard !indices.isEmpty else { return }
        guard !key.isEmpty else { notice = L10n.text("Add a translation service in Settings to start translating."); settingsRequested = true; return }
        for index in indices {
            if let error = Self.pageRangeError(jobs[index].pages, pageCount: jobs[index].pageCount) { notice = error; return }
            if !FileManager.default.isReadableFile(atPath: jobs[index].input.path) { notice = L10n.format("The original file has moved. Locate “%@” again.", jobs[index].title); return }
        }
        for index in indices {
            queuedProviders[jobs[index].id] = captured.provider.request(apiKey: key)
            jobs[index].outputDirectory = URL(fileURLWithPath: captured.outputPath)
            jobs[index].status = .queued; jobs[index].stage = L10n.text("Waiting to translate"); jobs[index].progress = 0; jobs[index].error = nil
            jobs[index].providerName = captured.provider.name
        }
        paused = false; save()
        if engineReady { startNext() } else if !checking { checkEngine() }
    }

    private func startNext() {
        guard !exiting, !paused, !running, engineReady,
              let index = jobs.firstIndex(where: { $0.status == .queued }),
              let provider = queuedProviders.removeValue(forKey: jobs[index].id) else { return }
        let directory = jobs[index].outputDirectory.appendingPathComponent(
            "\(String(jobs[index].title.prefix(60)))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            jobs[index].status = .failed; jobs[index].stage = L10n.text("Incomplete"); jobs[index].error = L10n.text("Could not create the output folder. Choose a writable location in Settings.")
            save(); startNext(); return
        }
        jobs[index].outputDirectory = directory
        jobs[index].status = .running; jobs[index].stage = L10n.text("Preparing translation"); jobs[index].progress = 0
        let job = jobs[index]; activeID = job.id; cancelling = false; save()
        if selectedJob?.id == job.id { selectVariant(.original) }
        let request = BackendRequest(operation: "translate", input: job.input.path, output: directory.path,
            source: job.source, target: job.target, pages: job.pages, mode: job.mode, provider: provider)
        session = BackendSession(request: request, command: runtimeCommand, onEvent: { [weak self] event in self?.receive(event, id: job.id) },
                                 onExit: { [weak self] code in self?.workerExited(code, id: job.id) })
        do { try session?.start() }
        catch { jobs[index].error = error.localizedDescription; workerExited(1, id: job.id) }
    }

    private func receive(_ event: BridgeEvent, id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .running else { return }
        switch event.type {
        case "finish":
            guard let outputs = event.outputs, hasReadableOutputs(outputs, for: jobs[index]) else {
                jobs[index].status = .failed; jobs[index].stage = jobs[index].status.label
                jobs[index].error = L10n.text("Translation did not produce all requested readable PDFs. Your original and previous results have been kept. Try again.")
                save(); return
            }
            jobs[index].outputs = outputs; jobs[index].progress = 100
            jobs[index].status = .completed; jobs[index].stage = L10n.text("Translation complete")
            jobs[index].readingPositions.removeValue(forKey: DocumentVariant.translated.rawValue)
            jobs[index].readingPositions.removeValue(forKey: DocumentVariant.bilingual.rawValue)
            if selectedJob?.id == id { selectVariant(jobs[index].mono != nil ? .translated : .bilingual) }
            save()
        case "error":
            jobs[index].status = cancelling ? .cancelled : .failed
            jobs[index].error = cancelling ? nil : (event.localizedMessage ?? L10n.text("Translation failed. Try again."))
            jobs[index].stage = jobs[index].status.label; save()
        case "cancelled": jobs[index].status = .cancelled; jobs[index].stage = L10n.text("Cancelled"); save()
        default:
            if let stage = event.stage { jobs[index].stage = readableStage(stage) }
            if let progress = event.overallProgress, progress.isFinite { jobs[index].progress = min(99.9, max(jobs[index].progress, progress)) }
        }
    }

    private func hasReadableOutputs(_ outputs: [String: String], for job: TranslationJob) -> Bool {
        var result = job
        result.outputs = outputs
        let urls: [URL?]
        switch job.mode {
        case "mono": urls = [result.mono]
        case "dual": urls = [result.dual]
        default: urls = [result.mono, result.dual]
        }
        return urls.allSatisfy { url in
            guard let url, FileManager.default.isReadableFile(atPath: url.path),
                  let document = PDFDocument(url: url), !document.isLocked else { return false }
            return document.pageCount > 0
        }
    }

    private func workerExited(_ code: Int32, id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .running {
            jobs[index].status = cancelling || code == 2 ? .cancelled : .failed
            jobs[index].stage = jobs[index].status.label
            if jobs[index].status == .failed { jobs[index].error = jobs[index].error ?? L10n.text("The translation engine stopped. You can try again.") }
        }
        session = nil; activeID = nil; cancelling = false; save()
        if exiting { finishQuitIfPossible() } else { startNext() }
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if id == activeID { cancelling = true; jobs[index].stage = L10n.text("Stopping…"); session?.cancel() }
        else if jobs[index].status == .queued {
            queuedProviders.removeValue(forKey: id); jobs[index].status = .cancelled; jobs[index].stage = L10n.text("Cancelled"); save()
        }
    }

    func toggleQueuePause() {
        paused.toggle()
        if !paused { startNext() }
    }

    func remove(_ ids: Set<UUID>) {
        jobs.removeAll { ids.contains($0.id) && !$0.status.isBusy && $0.id != activeID }
        selection = selection.intersection(Set(jobs.map(\.id))); save()
    }
    func clearFinished() { remove(Set(jobs.filter { [.completed, .failed, .cancelled].contains($0.status) }.map(\.id))) }

    func relocate(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].status.isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.title = L10n.text("Locate Original")
        guard panel.runModal() == .OK, let url = panel.url,
              let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { return }
        jobs[index].input = url; jobs[index].pageCount = pdf.pageCount; save()
    }

    func exportCurrent() {
        guard let job = selectedJob, let url = job.url(for: variant), FileManager.default.fileExists(atPath: url.path) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url, destination != url else { return }
        do { try Data(contentsOf: url).write(to: destination, options: .atomic) }
        catch { notice = L10n.format("Could not export the document: %@", error.localizedDescription) }
    }

    func prepareToQuit() {
        exiting = true; paused = true
        credentialRequestGeneration = UUID()
        cancelLinkImport()
        for task in linkImportTasks.values { task.cancel() }
        for id in jobs.filter({ $0.status == .queued }).map(\.id) { cancel(id) }
        checkSession?.cancel(); serviceSession?.cancel(); save()
        if let activeID { cancel(activeID) } else { finishQuitIfPossible() }
    }

    private func finishQuitIfPossible() {
        guard exiting, !running, linkImportTasks.isEmpty, !quitCompletionSent else { return }
        quitCompletionSent = true; afterStop?()
    }

    private func readableStage(_ stage: String) -> String {
        let value = stage.lowercased()
        if value.contains("glossary") || value.contains("term") { return L10n.text("Preparing terminology") }
        if value.contains("translat") { return L10n.text("Translating text") }
        if value.contains("parse") { return L10n.text("Parsing document") }
        if value.contains("layout") { return L10n.text("Analyzing layout") }
        if value.contains("save") || value.contains("write") { return L10n.text("Saving translation") }
        if value.contains("font") { return L10n.text("Preparing fonts") }
        if value.contains("typeset") { return L10n.text("Typesetting translation") }
        return L10n.text("Processing document")
    }
}
