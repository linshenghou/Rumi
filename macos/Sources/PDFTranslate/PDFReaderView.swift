import AppKit
import Combine
import PDFKit
import SwiftUI

/// The toolbar talks to the existing PDFView; publishing task progress never rebuilds its document.
@MainActor
final class ReaderController: NSObject, ObservableObject {
    @Published private(set) var currentPage = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var zoomLabel = "100%"
    @Published var searchText = "" {
        didSet { if oldValue != searchText { scheduleSearch() } }
    }
    @Published var isSearching = false
    @Published private(set) var searchResultCount = 0
    @Published private(set) var currentSearchResult = 0
    @Published private(set) var isFinding = false

    private weak var pdfView: PDFView?
    private weak var searchDocument: PDFDocument?
    private var matches: [PDFSelection] = []
    private var searchWork: DispatchWorkItem?
    private var activeQuery = ""

    func zoomIn() {
        guard let pdfView, pdfView.document != nil else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
        synchronize()
    }

    func zoomOut() {
        guard let pdfView, pdfView.document != nil else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
        synchronize()
    }

    /// In continuous reading mode PDFKit fits the page width to the window.
    func fitPage() {
        guard let pdfView, pdfView.document != nil else { return }
        pdfView.autoScales = true
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
        synchronize()
    }

    func goToPage(_ number: Int) {
        guard let pdfView, let document = pdfView.document,
              number > 0, number <= document.pageCount,
              let page = document.page(at: number - 1) else { return }
        pdfView.go(to: page)
        synchronize()
    }

    func showSearch() { isSearching = true }

    func hideSearch() {
        isSearching = false
        searchText = ""
        pdfView?.window?.makeFirstResponder(pdfView)
    }

    func toggleSearch() { isSearching ? hideSearch() : showSearch() }

    func findNext() {
        guard !matches.isEmpty else { return }
        selectMatch(at: currentSearchResult % matches.count)
    }

    func findPrevious() {
        guard !matches.isEmpty else { return }
        selectMatch(at: (currentSearchResult - 2 + matches.count) % matches.count)
    }

    fileprivate func attach(_ view: PDFView) {
        guard pdfView !== view else { return }
        detach()
        pdfView = view
        synchronize()
    }

    fileprivate func documentDidChange() {
        stopSearch()
        synchronize()
        if !searchText.isEmpty { scheduleSearch() }
    }

    fileprivate func documentWillChange(in view: PDFView) {
        if pdfView === view { stopSearch() }
    }

    fileprivate func synchronize() {
        let count = pdfView?.document?.pageCount ?? 0
        let index: Int
        if let document = pdfView?.document, let page = pdfView?.currentPage {
            let found = document.index(for: page)
            index = found == NSNotFound ? 0 : found + 1
        } else { index = 0 }
        let zoom = L10n.format("%d%%", Int(((pdfView?.scaleFactor ?? 1) * 100).rounded()))
        if pageCount != count { pageCount = count }
        if currentPage != index { currentPage = index }
        if zoomLabel != zoom { zoomLabel = zoom }
    }

    fileprivate func detach() {
        stopSearch()
        pdfView = nil
        synchronize()
    }

    fileprivate func detach(ifShowing view: PDFView) {
        if pdfView === view { detach() }
    }

    private func stopSearch() {
        searchWork?.cancel()
        searchWork = nil
        // Remove observers before cancelling: cancellation may send the end-find notification.
        if let document = searchDocument {
            NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidFindMatch, object: document)
            NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidEndFind, object: document)
            document.cancelFindString()
        }
        searchDocument = nil
        activeQuery = ""
        if !matches.isEmpty { pdfView?.clearSelection() }
        matches.removeAll()
        searchResultCount = 0
        currentSearchResult = 0
        isFinding = false
        pdfView?.highlightedSelections = nil
    }

    private func scheduleSearch() {
        stopSearch()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let document = pdfView?.document else { return }
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document, self.pdfView?.document === document,
                  self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.searchDocument = document
            self.activeQuery = query
            self.isFinding = true
            NotificationCenter.default.addObserver(self, selector: #selector(self.foundMatch(_:)),
                name: .PDFDocumentDidFindMatch, object: document)
            NotificationCenter.default.addObserver(self, selector: #selector(self.finishedFinding(_:)),
                name: .PDFDocumentDidEndFind, object: document)
            document.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    @objc private func foundMatch(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument,
              document === searchDocument, !activeQuery.isEmpty,
              let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
        matches.append(selection)
        searchResultCount = matches.count
        // Highlight just the current result while searching large documents; do not redraw all pages per match.
        if matches.count == 1 { selectMatch(at: 0) }
    }

    @objc private func finishedFinding(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument, document === searchDocument else { return }
        isFinding = false
    }

    private func selectMatch(at index: Int) {
        guard matches.indices.contains(index), let pdfView else { return }
        let match = matches[index]
        currentSearchResult = index + 1
        pdfView.highlightedSelections = [match]
        // Keep stepping through matches immediate, including with Reduce Motion enabled.
        pdfView.setCurrentSelection(match, animate: false)
        pdfView.scrollSelectionToVisible(nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

struct PDFReaderView: NSViewRepresentable {
    let url: URL
    let controller: ReaderController
    var position: ReadingPosition?
    let onPositionChange: (ReadingPosition) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> ReaderCanvas {
        let canvas = ReaderCanvas()
        context.coordinator.observe(canvas)
        return canvas
    }

    func updateNSView(_ canvas: ReaderCanvas, context: Context) {
        context.coordinator.update(canvas, url: url, position: position,
            onPositionChange: onPositionChange, onFailure: onFailure)
    }

    static func dismantleNSView(_ canvas: ReaderCanvas, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let controller: ReaderController
        private weak var canvas: ReaderCanvas?
        private var identity: PDFFileIdentity?
        private var generation = UUID()
        private var restoring = false
        private var positionWork: DispatchWorkItem?
        private var onPositionChange: ((ReadingPosition) -> Void)?

        init(controller: ReaderController) { self.controller = controller }

        func observe(_ canvas: ReaderCanvas) {
            self.canvas = canvas
            NotificationCenter.default.addObserver(self, selector: #selector(viewChanged(_:)),
                name: .PDFViewPageChanged, object: canvas.pdfView)
            NotificationCenter.default.addObserver(self, selector: #selector(viewChanged(_:)),
                name: .PDFViewScaleChanged, object: canvas.pdfView)
        }

        func update(_ canvas: ReaderCanvas, url: URL, position: ReadingPosition?,
                    onPositionChange: @escaping (ReadingPosition) -> Void,
                    onFailure: @escaping (String) -> Void) {
            let next = PDFFileIdentity(url: url)
            guard identity != next else {
                self.onPositionChange = onPositionChange
                return
            }
            flushPosition()
            identity = next
            self.onPositionChange = onPositionChange
            generation = UUID()
            let token = generation
            // Updating the representable may occur during a SwiftUI render. All published state
            // changes are deferred, and each load owns a token so a slower previous file cannot win.
            DispatchQueue.main.async { [weak self, weak canvas] in
                guard let self, let canvas, self.generation == token else { return }
                self.restoring = true
                self.controller.attach(canvas.pdfView)
                self.controller.documentWillChange(in: canvas.pdfView)
                canvas.pdfView.document = nil
                self.controller.documentDidChange()
                canvas.showLoading()
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = LoadedPDF.load(next.url)
                    DispatchQueue.main.async { [weak self, weak canvas] in
                        guard let self, let canvas, self.generation == token else { return }
                        switch result {
                        case .failure(let error):
                            self.restoring = false
                            canvas.showFailure(error.message)
                            onFailure(error.message)
                        case .success(let document):
                            canvas.pdfView.document = document
                            canvas.pdfView.layoutDocumentView()
                            // Restore after AppKit has sized the document's scroll view.
                            DispatchQueue.main.async { [weak self, weak canvas] in
                                guard let self, let canvas, self.generation == token else { return }
                                self.restore(position, in: canvas.pdfView)
                                canvas.showDocument()
                                self.restoring = false
                                self.controller.documentDidChange()
                                self.schedulePosition()
                            }
                        }
                    }
                }
            }
        }

        private func restore(_ position: ReadingPosition?, in view: PDFView) {
            guard let document = view.document, document.pageCount > 0 else { return }
            let index = min(max(position?.pageIndex ?? 0, 0), document.pageCount - 1)
            let auto = position?.autoScales ?? true
            view.autoScales = auto
            if auto {
                view.scaleFactor = view.scaleFactorForSizeToFit
            } else if let scale = position?.scaleFactor, scale.isFinite, scale > 0 {
                view.scaleFactor = min(max(CGFloat(scale), view.minScaleFactor), view.maxScaleFactor)
            }
            if let page = document.page(at: index) { view.go(to: page) }
        }

        @objc private func viewChanged(_ notification: Notification) {
            guard !restoring else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.restoring else { return }
                self.controller.synchronize()
                self.schedulePosition()
            }
        }

        private func currentPosition() -> ReadingPosition? {
            guard !restoring, let view = canvas?.pdfView,
                  let document = view.document, let page = view.currentPage else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound, view.scaleFactor.isFinite else { return nil }
            return ReadingPosition(pageIndex: index, scaleFactor: Double(view.scaleFactor), autoScales: view.autoScales)
        }

        private func schedulePosition() {
            positionWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let position = self.currentPosition() else { return }
                self.onPositionChange?(position)
            }
            positionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        private func flushPosition() {
            positionWork?.cancel()
            positionWork = nil
            if let position = currentPosition(), let callback = onPositionChange {
                DispatchQueue.main.async { callback(position) }
            }
        }

        func dismantle() {
            flushPosition()
            generation = UUID()
            NotificationCenter.default.removeObserver(self)
            if let view = canvas?.pdfView {
                controller.documentWillChange(in: view)
                view.document?.cancelFindString()
                view.document = nil
                DispatchQueue.main.async { [controller] in controller.detach(ifShowing: view) }
            }
            canvas = nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Includes modification metadata so replacing a result at the same URL refreshes its contents.
private struct PDFFileIdentity: Equatable {
    let url: URL
    let modificationDate: Date?
    let size: Int?

    init(url: URL) {
        self.url = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modificationDate = values?.contentModificationDate
        size = values?.fileSize
    }
}

private enum LoadedPDF {
    struct Failure: Error { let message: String }

    static func load(_ url: URL) -> Result<PDFDocument, Failure> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(Failure(message: L10n.text("The file was moved or deleted. Locate it to continue.")))
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .failure(Failure(message: L10n.text("This file can’t be read. Check its access permissions.")))
        }
        guard let document = PDFDocument(url: url) else {
            return .failure(Failure(message: L10n.text("This PDF can’t be opened. It may be damaged.")))
        }
        guard !document.isLocked else {
            return .failure(Failure(message: L10n.text("This PDF is password protected. Unlock it before importing.")))
        }
        guard document.pageCount > 0 else {
            return .failure(Failure(message: L10n.text("This PDF has no readable pages.")))
        }
        return .success(document)
    }
}

@MainActor
final class ReaderCanvas: NSView {
    let pdfView = PDFView()
    private let progress = NSProgressIndicator()
    private let message = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 8
        pdfView.autoScales = true
        pdfView.setAccessibilityLabel(L10n.text("Paper Reader"))
        progress.style = .spinning
        progress.controlSize = .regular
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel(L10n.text("Opening Document"))
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isSelectable = true
        message.isHidden = true
        for view in [pdfView, progress, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLoading() {
        message.isHidden = true
        progress.startAnimation(nil)
    }

    func showFailure(_ text: String) {
        progress.stopAnimation(nil)
        message.stringValue = text
        message.isHidden = false
    }

    func showDocument() {
        progress.stopAnimation(nil)
        message.isHidden = true
    }
}
