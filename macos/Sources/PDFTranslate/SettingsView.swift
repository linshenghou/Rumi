import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = AppPreferences()
    @State private var apiKey = ""
    @State private var message: String?
    @State private var loading = true
    @State private var advanced = false
    @State private var tab = "service"
    @State private var keyLoading = false
    @State private var keyLoaded = false
    @State private var keyEdited = false
    @State private var keyAccount = ""
    @State private var keyError: String?
    @State private var keyLoadID = UUID()
    @State private var keyLoadTask: Task<Void, Never>?
    @State private var saving = false

    var body: some View {
        TabView(selection: $tab) {
            service.tag("service").tabItem { Label("Translation Service", systemImage: "network") }
            general.tag("general").tabItem { Label("General", systemImage: "slider.horizontal.3") }
            about.tag("about").tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 530, height: 520)
        .onAppear { load() }
        .onDisappear { cancelKeyLoad() }
    }

    private var service: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Service", selection: $draft.provider.kind) {
                        Text("DeepSeek").tag("deepseek")
                        Text("Custom Compatible API").tag("compatible")
                    }
                    .onChange(of: draft.provider.kind) { _, value in
                        guard !loading else { return }
                        if value == "deepseek" { draft.provider.baseURL = "https://api.deepseek.com/v1"; draft.provider.model = "deepseek-flash"; draft.provider.thinkingMode = "disabled" }
                        else { draft.provider.baseURL = ""; draft.provider.model = ""; draft.provider.thinkingMode = "" }
                        draft.provider.reasoningEffort = ""
                        providerChanged()
                        message = nil; model.serviceMessage = nil
                    }
                    if draft.provider.kind == "compatible" {
                        TextField("Base URL", text: $draft.provider.baseURL, prompt: Text("https://example.com/v1"))
                            .onChange(of: draft.provider.baseURL) { _, _ in
                                if !loading { providerChanged(debounce: true); model.serviceMessage = nil }
                            }
                    }
                    TextField("Model", text: $draft.provider.model)
                    SecureField("API Key", text: Binding(get: { apiKey }, set: editKey), prompt: Text("Enter your API key"))
                        .privacySensitive()
                    keyStatus
                } footer: {
                    Text("Your API key is stored in this Mac’s Keychain. Document text is sent to your chosen service for translation. Your provider bills API usage.")
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        if draft.provider.kind == "deepseek" {
                            Picker("Thinking Mode", selection: $draft.provider.thinkingMode) {
                                Text("Off").tag("disabled"); Text("On").tag("enabled"); Text("Model Default").tag("")
                            }
                        }
                        Picker("Reasoning Effort", selection: $draft.provider.reasoningEffort) {
                            Text("Model Default").tag("")
                            if draft.provider.kind == "compatible" {
                                Text("Minimal").tag("minimal"); Text("Low").tag("low"); Text("Medium").tag("medium")
                            }
                            Text("High").tag("high"); Text("Maximum").tag("max")
                        }
                        .disabled(draft.provider.kind == "deepseek" && draft.provider.thinkingMode != "enabled")
                    }
                    HStack {
                        Button("Test Connection") { message = nil; model.testService(draft.provider, key: apiKey) }
                            .disabled(model.serviceBusy || apiKey.isEmpty)
                        if model.serviceBusy { ProgressView().controlSize(.small) }
                        Spacer()
                        Menu("Import Configuration") {
                            Button("Import Existing pdf2zh Configuration") { importConfig() }
                            Button("Choose Configuration File…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .data]
                                if panel.runModal() == .OK, let url = panel.url { importConfig(path: url.path) }
                            }
                        }.disabled(model.serviceBusy)
                    }
                } footer: { Text("Testing sends a short request and may incur a small API charge.") }
                if let text = message ?? model.serviceMessage {
                    Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.formStyle(.grouped).disabled(saving)
            saveBar
        }
    }

    private var general: some View {
        VStack(spacing: 0) {
            Form {
                Section("Defaults for New Papers") {
                    Picker("Source Language", selection: $draft.source) {
                        ForEach(Languages.all, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Translate To", selection: $draft.target) {
                        ForEach(Languages.all, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Output Documents", selection: $draft.mode) {
                        Text("Translated and Bilingual").tag("both"); Text("Translated Only").tag("mono"); Text("Bilingual Only").tag("dual")
                    }
                }
                Section {
                    LabeledContent("Save To") {
                        Text(URL(fileURLWithPath: draft.outputPath).lastPathComponent).lineLimit(1).help(draft.outputPath)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            panel.canCreateDirectories = true; panel.directoryURL = URL(fileURLWithPath: draft.outputPath)
                            if panel.runModal() == .OK, let url = panel.url { draft.outputPath = url.path }
                        }
                    }
                } footer: {
                    Text("Each translation is saved separately. Removing a paper from the list keeps its original and translated files.")
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped).disabled(saving)
            saveBar
        }
    }

    private var saveBar: some View {
        HStack {
            Button("Revert to Saved Settings") { load() }
                .disabled(saving)
            Spacer()
            if saving {
                ProgressView().controlSize(.small).accessibilityLabel("Saving Settings")
            }
            Button("Save", action: saveSettings)
                .keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
                .disabled(model.serviceBusy || saving)
        }.padding(20)
    }

    private var about: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 80, height: 80)
            Text("Rumi").font(.title2.bold())
            Text("Bring knowledge closer.").foregroundStyle(.secondary)
            Text(L10n.format("Version %@ · Apple Silicon", ReleaseInfo.current.displayVersion))
                .font(.caption).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 7)
            Text("Built on PDFMathTranslate-next and BabelDOC\nDocuments are processed locally and translated with your chosen API.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Link("Upstream Open Source Project", destination: URL(string: "https://github.com/PDFMathTranslate-next/PDFMathTranslate-next")!)
            HStack {
                Link("Rumi Source", destination: ReleaseInfo.current.repositoryURL)
                Link("Feedback", destination: ReleaseInfo.current.url("issues"))
                Link("Privacy", destination: ReleaseInfo.current.url("blob/main/PRIVACY.md"))
                Link("Releases", destination: ReleaseInfo.current.url("releases"))
            }
            Button("Source Code Information") {
                if let url = Bundle.main.url(forResource: "SOURCE", withExtension: "txt") { NSWorkspace.shared.open(url) }
            }.buttonStyle(.link)
            Button("View Included Licenses") {
                if let resources = Bundle.main.resourceURL {
                    NSWorkspace.shared.open(resources.appendingPathComponent("ThirdPartyNotices", isDirectory: true))
                }
            }.buttonStyle(.link)
            Text("AGPL-3.0 · Community Beta · Not notarized").font(.caption).foregroundStyle(.tertiary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        loading = true; draft = model.preferences
        apiKey = ""; keyEdited = false; keyLoaded = false
        keyAccount = draft.provider.credentialAccount
        message = nil
        loadKey()
        model.serviceMessage = nil
        DispatchQueue.main.async { loading = false }
    }

    @ViewBuilder
    private var keyStatus: some View {
        if keyLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading saved API key…").font(.caption).foregroundStyle(.secondary)
            }
        } else if !keyLoaded && apiKey.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your saved key is unchanged. Enter a new key or load it from Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Load Saved Key") {
                    keyEdited = false
                    loadKey(allowAuthentication: true)
                }
                .controlSize(.small)
                .accessibilityHint("Read the saved API key. macOS may ask you to authorize access.")
                Button("Import Key from Previous App") { importPreviousKey() }
                    .controlSize(.small)
            }
        }
    }

    private func editKey(_ value: String) {
        // An explicit edit always wins over a delayed or cancelled Keychain response.
        cancelKeyLoad()
        apiKey = value
        keyEdited = true
        keyError = nil
        message = nil
    }

    private func importPreviousKey() {
        cancelKeyLoad()
        let id = UUID()
        keyLoadID = id
        let config = draft.provider
        keyLoading = true
        keyError = nil
        keyLoadTask = Task { @MainActor in
            do {
                let value = try await model.importLegacyAPIKey(for: config)
                guard !Task.isCancelled, keyLoadID == id,
                      draft.provider.credentialAccount == config.credentialAccount else { return }
                if let value, !value.isEmpty {
                    apiKey = value; keyEdited = true; keyLoaded = false
                    message = L10n.text("Key imported. Click Save to store it in Rumi. The previous key is unchanged.")
                } else {
                    keyError = L10n.text("No previous key found. Enter a new API key.")
                }
            } catch {
                guard !Task.isCancelled, keyLoadID == id else { return }
                keyError = error.localizedDescription
            }
            keyLoading = false
            keyLoadTask = nil
        }
    }

    private func providerChanged(debounce: Bool = false) {
        guard draft.provider.credentialAccount != keyAccount else { return }
        apiKey = ""; keyEdited = false; keyLoaded = false
        keyAccount = draft.provider.credentialAccount
        loadKey(debounce: debounce)
    }

    private func loadKey(allowAuthentication: Bool = false, debounce: Bool = false) {
        cancelKeyLoad()
        let id = UUID()
        keyLoadID = id
        let config = draft.provider
        keyLoading = true
        keyError = nil
        keyLoadTask = Task { @MainActor in
            do {
                if debounce { try await Task.sleep(nanoseconds: 300_000_000) }
                try Task.checkCancellation()
                let value = try await model.loadAPIKey(for: config, allowAuthentication: allowAuthentication)
                guard !Task.isCancelled, keyLoadID == id,
                      draft.provider.credentialAccount == config.credentialAccount, !keyEdited else { return }
                apiKey = value
                keyLoaded = true
                keyLoading = false
                keyLoadTask = nil
            } catch {
                guard !Task.isCancelled, keyLoadID == id,
                      draft.provider.credentialAccount == config.credentialAccount, !keyEdited else { return }
                keyLoading = false
                keyLoaded = false
                keyLoadTask = nil
                // Passive loads only consult the cache. Authentication requires the explicit button.
                keyError = allowAuthentication ? error.localizedDescription : nil
            }
        }
    }

    private func cancelKeyLoad() {
        keyLoadID = UUID()
        keyLoadTask?.cancel()
        keyLoadTask = nil
        keyLoading = false
    }

    private func saveSettings() {
        guard !saving, !model.serviceBusy else { return }
        cancelKeyLoad()
        let value = draft
        let replacement = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // nil preserves the stored credential. A blank unread field can never request deletion.
        let keyChange: String? = keyEdited && (!replacement.isEmpty || keyLoaded) ? replacement : nil
        saving = true
        message = nil
        Task { @MainActor in
            do {
                try await model.applySettings(value, apiKey: keyChange)
                if draft.provider.credentialAccount == value.provider.credentialAccount {
                    keyEdited = false
                    if keyChange != nil { keyLoaded = true; keyError = nil }
                }
                message = L10n.text("Settings saved.")
            } catch { message = error.localizedDescription }
            saving = false
        }
    }

    private func importConfig(path: String? = nil) {
        message = nil
        model.importLegacyConfig(path: path) { provider in
            cancelKeyLoad()
            loading = true; draft.provider = provider.configuration; apiKey = provider.apiKey
            keyAccount = draft.provider.credentialAccount
            keyEdited = true; keyLoaded = false; keyError = nil
            DispatchQueue.main.async { loading = false }
        }
    }
}
