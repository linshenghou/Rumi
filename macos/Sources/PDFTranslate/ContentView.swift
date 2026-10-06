import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var reader = ReaderController()
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @State private var targeted = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var optionsVisible = false
    @State private var readerError: String?
    @State private var pageNumber = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 238, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer(minLength: 8)
                        if !model.engineReady && !model.checking {
                            Button("Retry Check", action: model.checkEngine)
                        }
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss Notice")
                    }.padding(12).background(.quaternary.opacity(0.4))
                    Divider()
                }
                if let job = model.selectedJob { document(job) }
                else if model.selection.count > 1 { multipleSelection }
                else { emptyState }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.selectedJob?.title ?? "Rumi")
            .toolbar { mainToolbar }
        }
        .frame(minWidth: 820, minHeight: 600)
        .overlay {
            if targeted {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                    Label("Release to Add PDF", systemImage: "arrow.down.doc")
                        .font(.callout.weight(.medium)).padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule()).padding(.top, 16)
                }.padding(7).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted, perform: acceptDrop)
        .onChange(of: model.settingsRequested) { _, value in
            if value { openSettings(); model.settingsRequested = false }
        }
        .onChange(of: model.findRequest) { _, _ in reader.showSearch(); searchFocused = true }
        .onChange(of: reader.isSearching) { _, value in if value { searchFocused = true } }
        .onChange(of: model.selection) { _, _ in readerError = nil }
        .onChange(of: model.variant) { _, _ in readerError = nil }
        .sheet(isPresented: $model.linkImportPresented) { ArxivImportView(model: model) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !model.jobs.isEmpty {
                PDFImportCard(compact: true, isTargeted: targeted, action: model.chooseFiles,
                              linkAction: model.presentLinkImport)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            }
            List(selection: $model.selection) {
                Section("Papers") {
                    ForEach(model.jobs) { job in
                        DocumentRow(job: job).tag(job.id)
                            .contextMenu {
                                if job.status.isBusy {
                                    Button("Cancel Translation") { model.cancel(job.id) }
                                } else {
                                    Button(L10n.text(job.status == .completed ? "Translate Again" : "Translate")) { model.requestTranslation([job.id]) }
                                }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.input]) }
                                Button("Locate Original…") { model.relocate(job.id) }.disabled(job.status.isBusy)
                                Divider()
                                Button("Remove from List") { model.remove([job.id]) }.disabled(job.status.isBusy)
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.jobs.isEmpty {
                    VStack(spacing: 7) {
                        Text("Your Papers").font(.callout)
                        Text("Add a paper to continue reading here").font(.caption).foregroundStyle(.tertiary)
                    }.foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if model.importing || model.checking { ProgressView().controlSize(.mini) }
                Text(sidebarStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.hasWork {
                    Button(action: model.toggleQueuePause) {
                        Image(systemName: model.paused ? "play.circle" : "pause.circle")
                    }.buttonStyle(.borderless).help(L10n.text(model.paused ? "Resume Queue" : "Pause After This Translation"))
                }
            }.padding(.horizontal, 14).padding(.vertical, 11)
        }
    }

    private var sidebarStatus: String {
        if model.importing { return L10n.text("Adding…") }
        if model.checking { return L10n.text("Preparing translation engine…") }
        if model.paused && model.hasWork { return L10n.text("Queue Paused") }
        if model.hasWork { return L10n.format("%d queued", model.waitingCount) }
        return model.jobs.count == 1 ? L10n.text("1 paper") : L10n.format("%d papers", model.jobs.count)
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        if columnVisibility == .detailOnly && !model.jobs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.chooseFiles) { Label("Add PDF", systemImage: "doc.badge.plus") }
                    .help("Add PDF (⌘O)")
            }
        }
        if model.selectedJob != nil {
            if #available(macOS 26.0, *) {
                ToolbarItemGroup(placement: .primaryAction) { readerControls }
                    .sharedBackgroundVisibility(.visible)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    readerControls.background(.regularMaterial, in: Capsule())
                }
            }
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { translationAction }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { translationAction }
        }
    }

    private var readerControls: some View {
        HStack(spacing: 3) {
            if let job = model.selectedJob, job.mono != nil || job.dual != nil {
                versionPicker
            }
            moreMenu
        }
        .padding(.horizontal, 3)
        .frame(height: 30)
    }

    @ViewBuilder
    private var versionPicker: some View {
        if let job = model.selectedJob, job.mono != nil || job.dual != nil {
            let variants = DocumentVariant.allCases.filter { job.url(for: $0) != nil }
            HStack(spacing: 1) {
                ForEach(variants) { variant in
                    Button { model.selectVariant(variant) } label: {
                        Text(variant.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(model.variant == variant || accessibilityContrast == .increased ? 1 : 0.76))
                            .fixedSize()
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(model.variant == variant ? versionSelectionFill : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.variant == variant ? .isSelected : [])
                    .help(L10n.format("Show %@", variant.label))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reading Version")
            .onMoveCommand { direction in
                guard direction == .left || direction == .right,
                      let index = variants.firstIndex(of: model.variant) else { return }
                let next = min(variants.count - 1, max(0, index + (direction == .right ? 1 : -1)))
                model.selectVariant(variants[next])
            }
        }
    }

    private var versionSelectionFill: Color {
        if colorScheme == .dark {
            return .white.opacity(accessibilityContrast == .increased ? 0.28 : 0.16)
        }
        return accessibilityContrast == .increased ? .black.opacity(0.14) : .white.opacity(0.88)
    }

    @ViewBuilder
    private var moreMenu: some View {
        if let job = model.selectedJob {
            Menu {
                Button { reader.toggleSearch() } label: {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                Button { optionsVisible = true } label: {
                    Label(L10n.format("Translation Options · %@", Languages.name(job.target)), systemImage: "slider.horizontal.3")
                }
                Divider()
                Button(action: model.exportCurrent) {
                    Label("Export Document…", systemImage: "square.and.arrow.up")
                }
                Button {
                    if let url = model.selectedJob?.url(for: model.variant) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in Preview", systemImage: "doc.text.magnifyingglass")
                }
                Button {
                    if let url = model.selectedJob?.url(for: model.variant) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            } label: {
                Label("More Actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 26)
            .help("More Actions")
            .accessibilityLabel("More Actions")
            .popover(isPresented: $optionsVisible) { TranslationOptions(model: model, id: job.id) }
        }
    }

    @ViewBuilder
    private var translationAction: some View {
        if let job = model.selectedJob, job.status.isBusy {
            TranslationAction(title: L10n.text(model.cancelling ? "Cancelling…" : "Cancel Translation"), compact: true,
                              isProcessing: !model.cancelling,
                              progress: job.progress) {
                model.cancel(job.id)
            }
            .disabled(model.cancelling && job.status == .running)
            .help("Cancel Current Translation")
        } else if model.selectedJob != nil || model.selection.count > 1 {
            TranslationAction(title: L10n.text(model.selectedJob?.status == .completed ? "Translate Again" : "Translate"), compact: true) {
                model.requestTranslation()
            }
            .disabled(model.eligibleSelection.isEmpty)
            .help(L10n.text(model.selection.count > 1 ? "Translate Selected Papers (⌘↩)" : "Translate Current Paper (⌘↩)"))
        }
    }

    private func document(_ job: TranslationJob) -> some View {
        VStack(spacing: 0) {
            if reader.isSearching { searchBar; Divider() }
            ZStack {
                if let url = job.url(for: model.variant) {
                    let displayedVariant = model.variant
                    PDFReaderView(url: url, controller: reader, position: job.readingPositions[displayedVariant.rawValue],
                        onPositionChange: { model.remember($0, id: job.id, variant: displayedVariant) },
                        onFailure: { readerError = $0 })
                }
                if let error = readerError {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.questionmark").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if model.variant == .original {
                            Button("Locate Original…") { model.relocate(job.id); readerError = nil }
                        } else { Button("Show Original") { model.selectVariant(.original) } }
                    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            if job.status.isBusy { taskStatus(job) }
            else if let error = job.error {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { model.requestTranslation([job.id]) }
                }.padding(12)
            }
            Divider()
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    TextField("Pages", text: $pageNumber).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 32)
                        .onSubmit { if let page = Int(pageNumber) { reader.goToPage(page) }; pageNumber = String(reader.currentPage) }
                        .onChange(of: reader.currentPage) { _, page in pageNumber = String(page) }
                        .onAppear { pageNumber = String(reader.currentPage) }
                        .accessibilityLabel("Go to Page")
                    Text(L10n.format("/ %d", reader.pageCount)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { reader.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                Text(reader.zoomLabel).monospacedDigit().frame(width: 40)
                Button { reader.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                Divider().frame(height: 12)
                Button("Fit Width") { reader.fitPage() }
            }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Document", text: $reader.searchText).textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { reader.findNext() }.onExitCommand { reader.hideSearch() }
                .onAppear { DispatchQueue.main.async { searchFocused = true } }
            if reader.isFinding { ProgressView().controlSize(.mini) }
            else if !reader.searchText.isEmpty {
                Text(reader.searchResultCount == 0 ? L10n.text("No Results") : L10n.format("%d / %d", reader.currentSearchResult, reader.searchResultCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { reader.findPrevious() } label: { Image(systemName: "chevron.up") }.help("Previous Match")
                .disabled(reader.searchResultCount == 0)
            Button { reader.findNext() } label: { Image(systemName: "chevron.down") }.help("Next Match")
                .disabled(reader.searchResultCount == 0)
            Button("Done") { reader.hideSearch() }
        }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func taskStatus(_ job: TranslationJob) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(job.stage)
                Spacer()
                if job.status == .running { Text(L10n.format("%d%%", Int(job.progress))).monospacedDigit() }
                else if !model.engineReady && !model.checking {
                    Button("Retry", action: model.checkEngine).buttonStyle(.borderless)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if job.status == .running { ProgressView(value: job.progress, total: 100).controlSize(.small) }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 9) {
                Text("Start with a paper").font(.system(size: 25, weight: .medium))
                Text("Add a paper to read and translate.").font(.callout).foregroundStyle(.secondary)
            }
            PDFImportCard(isTargeted: targeted, action: model.chooseFiles, linkAction: model.presentLinkImport)
                .frame(width: 320)
            Text("Preserves equations, figures, and page layout").font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }

    private var multipleSelection: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(L10n.format("%d papers selected", model.selection.count)).font(.title2)
            Text("Papers translate one at a time. Keep reading while you wait.").foregroundStyle(.secondary)
            Text("Choose Translate in the toolbar to begin").font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(); let lock = NSLock(); var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.add(urls) }
        return true
    }
}

private struct TranslationOptions: View {
    @ObservedObject var model: AppModel
    let id: UUID
    private var job: TranslationJob? { model.jobs.first { $0.id == id } }
    var body: some View {
        if let job {
            Form {
                Picker("Source Language", selection: Binding(get: { self.job?.source ?? "en" }, set: { model.updateOptions(id: id, source: $0) })) {
                    ForEach(Languages.all, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Translate To", selection: Binding(get: { self.job?.target ?? "zh-CN" }, set: { model.updateOptions(id: id, target: $0) })) {
                    ForEach(Languages.all, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Pages", text: Binding(get: { self.job?.pages ?? "" }, set: { model.updateOptions(id: id, pages: $0) }), prompt: Text("All Pages"))
                Text("For example, 1-5,8. Leave blank for the whole document.").font(.caption).foregroundStyle(.secondary)
                Picker("Output", selection: Binding(get: { self.job?.mode ?? "both" }, set: { model.updateOptions(id: id, mode: $0) })) {
                    Text("Translated and Bilingual").tag("both"); Text("Translated Only").tag("mono"); Text("Bilingual Only").tag("dual")
                }
                if let error = AppModel.pageRangeError(job.pages, pageCount: job.pageCount) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }.formStyle(.grouped).frame(width: 310).fixedSize(horizontal: false, vertical: true).disabled(job.status.isBusy)
        }
    }
}

private struct DocumentRow: View {
    let job: TranslationJob
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(.white)
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: "doc.text").foregroundStyle(.gray) }
            }.frame(width: 32, height: 43).clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.1), lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 5) {
                    if job.status == .running { ProgressView(value: job.progress, total: 100).progressViewStyle(.circular).controlSize(.mini) }
                    if job.status == .completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    if job.status == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                    Text(job.status == .ready ? (job.pageCount == 1 ? L10n.text("1 page") : L10n.format("%d pages", job.pageCount)) : job.status.label)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
        .task(id: job.input) {
            let url = job.input
            thumbnail = await Task.detached(priority: .utility) {
                PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: NSSize(width: 64, height: 86), for: .cropBox)
            }.value
        }
    }
}
