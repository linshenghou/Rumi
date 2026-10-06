import Foundation

enum JobStatus: String, Codable {
    case ready, queued, running, completed, failed, cancelled
    var label: String {
        switch self {
        case .ready: return L10n.text("Not Translated")
        case .queued: return L10n.text("Waiting")
        case .running: return L10n.text("Translating")
        case .completed: return L10n.text("Translated")
        case .failed: return L10n.text("Incomplete")
        case .cancelled: return L10n.text("Cancelled")
        }
    }
    var isBusy: Bool { self == .queued || self == .running }
}

enum DocumentVariant: String, Codable, CaseIterable, Identifiable {
    case original, translated, bilingual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return L10n.text("Original")
        case .translated: return L10n.text("Translation")
        case .bilingual: return L10n.text("Bilingual")
        }
    }
}

struct ReadingPosition: Codable, Equatable {
    var pageIndex: Int = 0
    var scaleFactor: Double = 1
    var autoScales: Bool = true
}

struct ServiceConfiguration: Codable, Equatable {
    var kind = "deepseek"
    var baseURL = "https://api.deepseek.com/v1"
    var model = "deepseek-flash"
    var thinkingMode = "disabled"
    var reasoningEffort = ""
    var name: String { kind == "deepseek" ? "DeepSeek" : L10n.text("Custom Service") }
    var effectiveURL: String { kind == "deepseek" ? "https://api.deepseek.com/v1" : baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var credentialAccount: String { "\(kind)|\(effectiveURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" }
    /// Normalize retired/default aliases without touching credentials or custom services.
    var normalizedForDesktop: ServiceConfiguration {
        guard kind == "deepseek" else { return self }
        let previousModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["", "deepseek-chat", "deepseek-reasoner", "deepseek-v4-flash"].contains(previousModel) else { return self }
        var result = self
        result.model = "deepseek-flash"
        if thinkingMode.isEmpty {
            if previousModel == "deepseek-chat" { result.thinkingMode = "disabled" }
            else if previousModel == "deepseek-reasoner" { result.thinkingMode = "enabled" }
        }
        return result
    }
    var validationError: String? {
        guard ["deepseek", "compatible"].contains(kind), ["", "disabled", "enabled"].contains(thinkingMode),
              (kind == "deepseek" ? ["", "high", "max"] : ["", "minimal", "low", "medium", "high", "max"]).contains(reasoningEffort) else {
            return L10n.text("Check the thinking mode and reasoning effort settings.")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L10n.text("Enter a model name.") }
        guard let url = URL(string: effectiveURL), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            return L10n.text("Enter an HTTPS endpoint. HTTP is supported for local services.")
        }
        return nil
    }
    func request(apiKey: String) -> ProviderRequest {
        ProviderRequest(kind: kind, baseURL: effectiveURL, model: model, apiKey: apiKey,
                        thinkingMode: thinkingMode, reasoningEffort: reasoningEffort)
    }

    enum CodingKeys: String, CodingKey { case kind, baseURL, model, thinkingMode, reasoningEffort }
}

extension ServiceConfiguration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "deepseek"
        self.init(kind: kind,
                  baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL) ?? (kind == "deepseek" ? "https://api.deepseek.com/v1" : ""),
                  model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
                  thinkingMode: try c.decodeIfPresent(String.self, forKey: .thinkingMode) ?? "",
                  reasoningEffort: try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? "")
    }
}

/// Credentials exist in memory and travel only through the helper's anonymous stdin pipe.
struct ProviderRequest: Codable {
    var kind: String
    var baseURL: String
    var model: String
    var apiKey: String
    var thinkingMode: String?
    var reasoningEffort: String?
    enum CodingKeys: String, CodingKey {
        case kind, model
        case baseURL = "base_url", apiKey = "api_key", thinkingMode = "thinking_mode", reasoningEffort = "reasoning_effort"
    }
    var configuration: ServiceConfiguration {
        ServiceConfiguration(kind: kind, baseURL: baseURL, model: model,
                             thinkingMode: thinkingMode ?? "", reasoningEffort: reasoningEffort ?? "").normalizedForDesktop
    }
}

struct TranslationJob: Identifiable, Codable {
    var id = UUID()
    var input: URL
    var outputDirectory: URL
    var source: String
    var target: String
    var pages: String
    var mode: String
    var config: String = "" // Read legacy history; never used to launch a new task.
    var status: JobStatus = .ready
    var progress: Double = 0
    var stage = L10n.text("Not Translated")
    var outputs: [String: String] = [:]
    var error: String?
    var created = Date()
    var pageCount: Int = 0
    var readingPositions: [String: ReadingPosition] = [:]
    var providerName: String = ""
    var lastVariant: DocumentVariant = .original
    var title: String { input.deletingPathExtension().lastPathComponent }
    var mono: URL? { (outputs["no_watermark_mono_pdf_path"] ?? outputs["mono_pdf_path"]).map { URL(fileURLWithPath: $0) } }
    var dual: URL? { (outputs["no_watermark_dual_pdf_path"] ?? outputs["dual_pdf_path"]).map { URL(fileURLWithPath: $0) } }
    func url(for variant: DocumentVariant) -> URL? {
        switch variant {
        case .original: return input
        case .translated: return mono
        case .bilingual: return dual
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, input, outputDirectory, source, target, pages, mode, config, status, progress, stage, outputs, error, created
        case pageCount, readingPositions, providerName, lastVariant
    }
    init(input: URL, outputDirectory: URL, source: String = "en", target: String = "zh-CN",
         pages: String = "", mode: String = "both", config: String = "") {
        self.input = input; self.outputDirectory = outputDirectory; self.source = source
        self.target = target; self.pages = pages; self.mode = mode; self.config = config
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        input = try c.decode(URL.self, forKey: .input)
        outputDirectory = try c.decode(URL.self, forKey: .outputDirectory)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "en"
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? "zh-CN"
        pages = try c.decodeIfPresent(String.self, forKey: .pages) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "both"
        config = try c.decodeIfPresent(String.self, forKey: .config) ?? ""
        status = try c.decodeIfPresent(JobStatus.self, forKey: .status) ?? .ready
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? status.label
        outputs = try c.decodeIfPresent([String: String].self, forKey: .outputs) ?? [:]
        error = try c.decodeIfPresent(String.self, forKey: .error)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        readingPositions = try c.decodeIfPresent([String: ReadingPosition].self, forKey: .readingPositions) ?? [:]
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        lastVariant = try c.decodeIfPresent(DocumentVariant.self, forKey: .lastVariant) ?? .original
    }
}

struct AppPreferences: Codable, Equatable {
    var version = 2
    var outputPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PDF 翻译").path
    var source = "en"
    var target = "zh-CN"
    var mode = "both"
    var provider = ServiceConfiguration()
    var legacyConfigPath = ""
    enum CodingKeys: String, CodingKey { case version, outputPath, source, target, mode, provider, legacyConfigPath, configPath }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported preferences version")
        }
        version = 2
        outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath) ?? outputPath
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? source
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? target
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        provider = (try c.decodeIfPresent(ServiceConfiguration.self, forKey: .provider) ?? provider).normalizedForDesktop
        legacyConfigPath = try c.decodeIfPresent(String.self, forKey: .legacyConfigPath)
            ?? c.decodeIfPresent(String.self, forKey: .configPath) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(outputPath, forKey: .outputPath)
        try c.encode(source, forKey: .source); try c.encode(target, forKey: .target)
        try c.encode(mode, forKey: .mode); try c.encode(provider, forKey: .provider)
        try c.encode(legacyConfigPath, forKey: .legacyConfigPath)
    }
}

struct HistoryArchive: Codable { var version = 2; var jobs: [TranslationJob] }

struct BackendRequest: Encodable {
    var operation: String
    var input: String?
    var output: String?
    var source: String?
    var target: String?
    var pages: String?
    var mode: String?
    var provider: ProviderRequest?
    var configPath: String?
    enum CodingKeys: String, CodingKey {
        case operation, input, output, source, target, pages, mode, provider
        case configPath = "config_path"
    }
}

struct BridgeEvent: Decodable {
    var type: String
    var stage: String?
    var overallProgress: Double?
    var outputs: [String: String]?
    var message: String?
    var code: String?
    var provider: ProviderRequest?
    /// Error codes are stable protocol values; helper prose may be in a different
    /// language. Preserve unknown details without changing the helper protocol.
    var localizedMessage: String? {
        guard type == "error" else { return message }
        switch code {
        case "invalid_key": return L10n.text("Your API key is invalid or lacks access. Update it in translation service settings.")
        case "rate_limit": return L10n.text("The service is rate-limited or out of credit. Try again later or check your account.")
        case "network": return L10n.text("Could not connect to the translation service. Check your connection and endpoint.")
        case "configuration": return L10n.text("The translation service configuration is invalid. Check the endpoint, model, and API key.")
        case "invalid_pdf": return L10n.text("This PDF could not be translated. Choose a complete, unencrypted PDF with selectable text.")
        case "output_permission": return L10n.text("Could not write to the output folder. Choose a writable location.")
        case "engine": return L10n.text("The translation engine or its resources are missing or damaged. Reinstall the app.")
        case "unexpected": return L10n.text("Translation could not be completed. Try again or check the service and document.")
        default: return message
        }
    }
    enum CodingKeys: String, CodingKey {
        case type, stage, outputs, message, code, provider
        case overallProgress = "overall_progress"
    }
}

struct EventDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) -> [BridgeEvent] {
        buffer.append(data)
        var events: [BridgeEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            if let event = try? JSONDecoder().decode(BridgeEvent.self, from: Data(buffer[..<newline])) { events.append(event) }
            buffer.removeSubrange(...newline)
        }
        if buffer.count > 1_048_576 { buffer.removeAll() }
        return events
    }
}

enum InputCollector {
    static func collect(_ urls: [URL]) -> (files: [URL], rejected: Int) {
        var files: [URL] = [], seen = Set<String>(), rejected = 0
        func append(_ url: URL) {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.pathExtension.lowercased() == "pdf",
                  (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: canonical.path) else { rejected += 1; return }
            if seen.insert(canonical.path).inserted { files.append(canonical) }
        }
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                var found = false
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let child as URL in enumerator where child.pathExtension.lowercased() == "pdf" { found = true; append(child) }
                }
                if !found { rejected += 1 }
            } else { append(url) }
        }
        return (files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, rejected)
    }
}

enum Languages {
    static var all: [(String, String)] { [("en", L10n.text("English")), ("zh-CN", L10n.text("Simplified Chinese")), ("zh", L10n.text("Chinese")), ("zh-TW", L10n.text("Traditional Chinese")),
                      ("ja", L10n.text("Japanese")), ("ko", L10n.text("Korean")), ("de", L10n.text("German")), ("fr", L10n.text("French")), ("es", L10n.text("Spanish")),
                      ("ru", L10n.text("Russian")), ("pt", L10n.text("Portuguese")), ("it", L10n.text("Italian"))] }
    static func name(_ code: String) -> String { all.first { $0.0 == code }?.1 ?? code }
}
