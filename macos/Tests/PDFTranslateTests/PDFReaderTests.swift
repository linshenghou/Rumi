import AppKit
import CoreText
import PDFKit
import XCTest
@testable import PDFTranslate

@MainActor
final class PDFReaderTests: XCTestCase {
    func testReaderRestoresPositionWithoutReloadingForOrdinaryUpdates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paper.pdf")
        try writePDF(to: url, pages: 3)
        let controller = ReaderController()
        let canvas = makeCanvas()
        let coordinator = PDFReaderView.Coordinator(controller: controller)
        coordinator.observe(canvas)
        defer { coordinator.dismantle() }
        var saved: ReadingPosition?
        coordinator.update(canvas, url: url,
            position: ReadingPosition(pageIndex: 1, scaleFactor: 1.5, autoScales: false),
            onPositionChange: { saved = $0 }, onFailure: { XCTFail($0) })
        await waitUntil { controller.pageCount == 3 }
        XCTAssertEqual(controller.pageCount, 3)
        XCTAssertEqual(controller.currentPage, 2)
        XCTAssertEqual(canvas.pdfView.scaleFactor, 1.5, accuracy: 0.01)
        let firstDocument = try XCTUnwrap(canvas.pdfView.document)
        controller.goToPage(3)
        XCTAssertEqual(controller.currentPage, 3)

        // SwiftUI may update the representable on every progress tick, including a stale saved
        // position. That must not recreate the document or pull the reader away from their page.
        coordinator.update(canvas, url: url,
            position: ReadingPosition(pageIndex: 0, scaleFactor: 0.5, autoScales: false),
            onPositionChange: { saved = $0 }, onFailure: { XCTFail($0) })
        XCTAssertTrue(canvas.pdfView.document === firstDocument)
        XCTAssertEqual(controller.currentPage, 3)
        await waitUntil { saved?.pageIndex == 2 }
        XCTAssertEqual(saved?.pageIndex, 2)

        // Replacing a result at its existing URL must invalidate the document.
        try writePDF(to: url, pages: 4)
        coordinator.update(canvas, url: url, position: nil,
            onPositionChange: { saved = $0 }, onFailure: { XCTFail($0) })
        await waitUntil { controller.pageCount == 4 }
        XCTAssertEqual(controller.pageCount, 4)
        XCTAssertFalse(canvas.pdfView.document === firstDocument)
    }

    func testSearchFindsTextAndCancelsWhenSwitchingDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.pdf")
        let second = directory.appendingPathComponent("second.pdf")
        try writePDF(to: first, pages: 2)
        try writePDF(to: second, pages: 1, text: "Other content")
        let controller = ReaderController()
        let canvas = makeCanvas()
        let coordinator = PDFReaderView.Coordinator(controller: controller)
        coordinator.observe(canvas)
        defer { coordinator.dismantle() }
        coordinator.update(canvas, url: first, position: nil,
            onPositionChange: { _ in }, onFailure: { XCTFail($0) })
        await waitUntil { controller.pageCount == 2 }
        controller.showSearch()
        controller.searchText = "research"
        await waitUntil { controller.searchResultCount == 2 && !controller.isFinding }
        XCTAssertEqual(controller.searchResultCount, 2)
        XCTAssertEqual(controller.currentSearchResult, 1)
        controller.findNext()
        XCTAssertEqual(controller.currentSearchResult, 2)
        controller.findNext()
        XCTAssertEqual(controller.currentSearchResult, 1)
        controller.findPrevious()
        XCTAssertEqual(controller.currentSearchResult, 2)
        coordinator.update(canvas, url: second, position: nil,
            onPositionChange: { _ in }, onFailure: { XCTFail($0) })
        await waitUntil { controller.pageCount == 1 }
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(controller.searchResultCount, 0)
        controller.hideSearch()
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.searchText, "")
    }

    func testMissingCorruptAndLockedDocumentsReportFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = ReaderController()
        let canvas = makeCanvas()
        let coordinator = PDFReaderView.Coordinator(controller: controller)
        coordinator.observe(canvas)
        defer { coordinator.dismantle() }
        var failure: String?
        coordinator.update(canvas, url: directory.appendingPathComponent("missing.pdf"), position: nil,
            onPositionChange: { _ in XCTFail("A failed document cannot save a reading position") },
            onFailure: { failure = $0 })
        await waitUntil { failure != nil }
        XCTAssertEqual(failure, L10n.text("The file was moved or deleted. Locate it to continue."))
        XCTAssertEqual(controller.pageCount, 0)
        failure = nil
        let corrupt = directory.appendingPathComponent("corrupt.pdf")
        try Data("not a PDF".utf8).write(to: corrupt)
        coordinator.update(canvas, url: corrupt, position: nil,
            onPositionChange: { _ in XCTFail("A failed document cannot save a reading position") },
            onFailure: { failure = $0 })
        await waitUntil { failure != nil }
        XCTAssertEqual(failure, L10n.text("This PDF can’t be opened. It may be damaged."))
        XCTAssertNil(canvas.pdfView.document)

        let source = directory.appendingPathComponent("source.pdf")
        let locked = directory.appendingPathComponent("locked.pdf")
        try writePDF(to: source, pages: 1)
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.write(to: locked,
            withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "secret"]))
        failure = nil
        coordinator.update(canvas, url: locked, position: nil,
            onPositionChange: { _ in XCTFail("A locked document cannot save a reading position") },
            onFailure: { failure = $0 })
        await waitUntil { failure != nil }
        XCTAssertEqual(failure, L10n.text("This PDF is password protected. Unlock it before importing."))
        XCTAssertEqual(controller.pageCount, 0)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func makeCanvas() -> ReaderCanvas {
        _ = NSApplication.shared
        let canvas = ReaderCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        canvas.layoutSubtreeIfNeeded()
        return canvas
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePDF(to url: URL, pages: Int, text: String = "Research paper") throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 630)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "\(text) \(index + 1)", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
}
