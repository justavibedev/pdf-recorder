import XCTest
import PDFKit
import AVFoundation
import CoreText
import PDFRecorderCore
@testable import PDFRecorderAppSupport

/// Multiple source PDFs, controller state and portable storage, with no application or audio device started.
final class MultiPDFWorkflowTests: XCTestCase {
    @MainActor func testOpenThreePDFsKeepsDocumentBoundariesAndMixedGeometry() async throws {
        let fixture = try MultiPDFFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs(fixture.sources)
        defer { model.reviewTask?.cancel(); model.metadataSaveTask?.cancel() }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pdfDocuments.map(\.title), ["Biology", "Statistics", "Speaking Lab"])
        XCTAssertEqual(model.pdfDocuments.map(\.pageCount), [2, 1, 3])
        XCTAssertEqual(model.manifest?.pages.count, 6)
        XCTAssertEqual(model.currentDocumentPages, 0..<2)
        XCTAssertEqual(model.currentDocumentPageNumber, 1)
        let root = try XCTUnwrap(model.projectURL)
        let manifest = try ProjectStore.load(at: root)
        XCTAssertEqual(manifest.version, 4)
        XCTAssertEqual(Set(manifest.pdfDocuments.map(\.id)).count, 3)
        for (index, source) in manifest.pdfDocuments.enumerated() {
            XCTAssertEqual(try Data(contentsOf: ProjectStore.location(source.path, in: root)), fixture.bytes[index])
            XCTAssertEqual(try Data(contentsOf: fixture.sources[index]), fixture.bytes[index])
        }
        for (index, expectedSize) in fixture.displayedSizes.enumerated() {
            let page = try XCTUnwrap(model.pdfPage(at: index))
            XCTAssertEqual(PDFReading.displaySize(of: page), expectedSize)
            XCTAssertTrue((page.string ?? "").contains("GLOBAL PAGE \(index + 1)"), "Page \(index) must come from its own source document")
        }
        model.selectDocument(manifest.pdfDocuments[2].id)
        XCTAssertEqual(model.currentDocumentPages, 3..<6)
        XCTAssertEqual(model.pdf?.pageCount, 3)
        XCTAssertEqual(model.visiblePageIndices, [3, 4, 5])
        XCTAssertTrue(model.inputs.isEmpty)
        XCTAssertNil(model.player)
    }

    @MainActor func testAddingPDFsLeavesExistingTakesMetadataAndSelectionsIntact() async throws {
        let fixture = try MultiPDFFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs([fixture.sources[0]])
        let first = try addTake(to: model, page: 1, name: "Original explanation")
        let second = try addTake(to: model, page: 1, name: "Alternative explanation")
        model.navigate(to: 1); await model.reviewTask?.value
        model.useTake(first)
        model.updatePage { $0.notes = "Keep this explanation"; $0.targetSeconds = 75; $0.bookmarked = true }
        XCTAssertTrue(model.flushMetadata())
        let originalPage = try XCTUnwrap(model.manifest?.pages[1])
        let originalID = try XCTUnwrap(model.currentDocumentID)
        let originalRoot = try XCTUnwrap(model.projectURL)
        let originalAudio = try Data(contentsOf: ProjectStore.location(first.audioPath, in: originalRoot))
        let viewport = Viewport(zoom: 2, offset: Point(0.1, -0.2))
        model.scene.viewport = viewport
        model.addPDFs(Array(fixture.sources.dropFirst()))
        await model.reviewTask?.value
        defer { model.reviewTask?.cancel(); model.metadataSaveTask?.cancel() }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pdfDocuments.count, 3)
        XCTAssertEqual(model.manifest?.pages[1], originalPage)
        XCTAssertEqual(model.manifest?.pages[1].takes.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.manifest?.pages[1].selectedTakeID, first.id)
        XCTAssertEqual(model.projectURL, originalRoot)
        XCTAssertEqual(model.currentDocumentID, model.pdfDocuments[1].id)
        XCTAssertEqual(try Data(contentsOf: ProjectStore.location(first.audioPath, in: originalRoot)), originalAudio)
        model.selectDocument(originalID); await model.reviewTask?.value
        XCTAssertEqual(model.pageIndex, 1)
        XCTAssertEqual(model.scene.viewport, viewport)
        XCTAssertEqual(model.selectedTakeID, first.id)
        XCTAssertEqual(try ProjectStore.load(at: originalRoot).pages[1], originalPage)
    }

    @MainActor func testDocumentSwitchingAndPortableReopenRestoreIndependentPageViewports() async throws {
        let fixture = try MultiPDFFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs(fixture.sources)
        let firstTake = try addTake(to: model, page: 1, name: "Cell explanation")
        let finalTake = try addTake(to: model, page: 5, name: "Closing explanation")
        let documents = model.pdfDocuments
        let globalPages = [1, 2, 5]
        let positions = [Viewport(zoom: 2, offset: Point(0.1, -0.2)), Viewport(zoom: 1.5, offset: Point(-0.1, 0.1)), Viewport(zoom: 3, offset: Point(0.25, 0.15))]
        for index in 0..<3 {
            model.selectDocument(documents[index].id)
            model.navigate(to: globalPages[index]); await model.reviewTask?.value
            model.scene.viewport = positions[index]; model.rememberWorkspace()
        }
        for index in 0..<3 {
            model.selectDocument(documents[index].id); await model.reviewTask?.value
            XCTAssertEqual(model.pageIndex, globalPages[index])
            XCTAssertEqual(model.scene.viewport, positions[index])
        }
        XCTAssertEqual(model.manifest?.selectedTakes.map(\.take.id), [firstTake.id, finalTake.id])
        model.updatePage { $0.notes = "Closing notes remain with the third PDF" }
        XCTAssertTrue(model.flushMetadata()); model.rememberWorkspace()
        let sourceRoot = try XCTUnwrap(model.projectURL)
        let saved = fixture.workspace.appendingPathComponent("All lectures.pdfrecorder")
        try ProjectStore.saveCopy(from: sourceRoot, to: saved, manifest: XCTUnwrap(model.manifest))
        // Source documents can disappear; every PDF required for reopening is inside the project package.
        for source in fixture.sources { try FileManager.default.removeItem(at: source) }
        let reopened = AppModel(storageRoot: fixture.support, connectDevices: false)
        reopened.open(saved); await reopened.reviewTask?.value
        defer { model.reviewTask?.cancel(); model.metadataSaveTask?.cancel(); reopened.reviewTask?.cancel() }
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.pdfDocuments, documents)
        XCTAssertEqual(reopened.currentDocumentID, documents[2].id)
        XCTAssertEqual(reopened.pageIndex, 5)
        XCTAssertEqual(reopened.scene.viewport, positions[2])
        XCTAssertEqual(reopened.page?.notes, "Closing notes remain with the third PDF")
        XCTAssertEqual(reopened.manifest?.selectedTakes.map(\.take.id), [firstTake.id, finalTake.id])
        for index in 0..<3 {
            reopened.selectDocument(documents[index].id); await reopened.reviewTask?.value
            XCTAssertEqual(reopened.pageIndex, globalPages[index])
            XCTAssertEqual(reopened.scene.viewport, positions[index])
            XCTAssertEqual(reopened.currentDocumentPageNumber, index == 0 ? 2 : index == 1 ? 1 : 3)
        }
        XCTAssertTrue(reopened.inputs.isEmpty); XCTAssertNil(reopened.player)
    }

    @MainActor func testInvalidPDFInAddBatchPublishesNoPartialDocumentAndNavigationLocks() async throws {
        let fixture = try MultiPDFFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs([fixture.sources[0]])
        let before = try XCTUnwrap(model.manifest), root = try XCTUnwrap(model.projectURL)
        let corrupt = fixture.workspace.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: corrupt)
        model.addPDFs([fixture.sources[1], corrupt])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.manifest, before)
        XCTAssertEqual(try ProjectStore.load(at: root), before)
        model.errorMessage = nil; model.addPDFs([fixture.sources[1]])
        XCTAssertNil(model.errorMessage)
        let active = model.currentDocumentID
        model.mode = .paused
        defer { model.mode = .idle; model.reviewTask?.cancel() }
        model.selectDocument(model.pdfDocuments[0].id)
        XCTAssertEqual(model.currentDocumentID, active, "A paused take must keep document navigation locked")
        XCTAssertEqual(model.microphone.snapshot.time, 0)
    }

    @MainActor func testExportRangesAndChaptersAreLocalToTheCurrentPDF() async throws {
        let fixture = try MultiPDFFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs(fixture.sources)
        _ = try addTake(to: model, page: 1, name: "Biology")
        _ = try addTake(to: model, page: 3, name: "Opening")
        _ = try addTake(to: model, page: 5, name: "Ending")
        model.selectDocument(model.pdfDocuments[2].id); await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        model.exportScope = .included
        XCTAssertEqual(try model.exportSelection().map(\.page), [1, 3, 5])
        model.exportScope = .document
        XCTAssertEqual(try model.exportSelection().map(\.page), [3, 5])
        model.exportScope = .range; model.exportRange = "1, 3"
        XCTAssertEqual(try model.requestedExportPages(), [3, 5])
        model.exportRange = "4"
        XCTAssertThrowsError(try model.requestedExportPages(), "A PDF-local range cannot select a page from another source")
        model.exportScope = .chapter
        XCTAssertEqual(try model.requestedExportPages(), [3, 4, 5], "Without an outline, a chapter ends at the current PDF boundary")
        model.selectDocument(model.pdfDocuments[1].id)
        XCTAssertEqual(try model.requestedExportPages(), [2])
        XCTAssertTrue(try model.exportSelection().isEmpty)
    }

    @MainActor func testMissingImportedPDFEndsSearchWithVisibleError() async throws {
        let fixture = try MultiPDFFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs(fixture.sources)
        defer { model.searchTask?.cancel(); model.reviewTask?.cancel(); model.metadataSaveTask?.cancel() }
        XCTAssertNil(model.errorMessage)
        let manifest = try XCTUnwrap(model.manifest), root = try XCTUnwrap(model.projectURL)
        // The open workspace retains its PDF objects, but search must reopen each portable source.
        let missing = try ProjectStore.location(manifest.pdfDocuments[1].path, in: root)
        try FileManager.default.removeItem(at: missing)

        model.searchQuery = "GLOBAL PAGE"
        XCTAssertTrue(model.isSearching, "A nonempty query must enter the asynchronous indexing state")
        let search = try XCTUnwrap(model.searchTask)
        await search.value

        XCTAssertFalse(model.isSearching, "An unreadable source must not leave the search indicator running")
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("Could not search the PDFs"), "The failure must be visible to the user")
        XCTAssertEqual(model.manifest, manifest, "Search failure must leave document and take metadata intact")
        XCTAssertTrue(model.indexedPageText.isEmpty, "Partial results must not be published as a complete index")
        XCTAssertTrue(model.inputs.isEmpty)
        XCTAssertNil(model.player)
    }

    @MainActor private func addTake(to model: AppModel, page: Int, name: String) throws -> Take {
        let root = try XCTUnwrap(model.projectURL), manifest = try XCTUnwrap(model.manifest)
        var take = Take(duration: 0.3); take.name = name
        // Project timestamps use ISO-8601 seconds; keep fixture identity stable across the persisted round trip.
        take.createdAt = Date(timeIntervalSince1970: take.createdAt.timeIntervalSince1970.rounded(.down))
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let audio = try AVAudioFile(forWriting: ProjectStore.prepare(take, at: root), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_400)!
        buffer.frameLength = 2_400
        for index in 0..<2_400 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 8_000)) * 0.05 }
        try audio.write(from: buffer)
        model.manifest = try ProjectStore.commit(take, events: [.init(time: 0.1, action: .pointer(Point(0.4, 0.6)))], page: page, manifest: manifest, at: root)
        return take
    }
}

private struct MultiPDFFixture {
    let workspace: URL, support: URL
    let sources: [URL], bytes: [Data]
    let displayedSizes = [CGSize(width: 612, height: 792), CGSize(width: 612, height: 792), CGSize(width: 960, height: 540),
                          CGSize(width: 500, height: 700), CGSize(width: 900, height: 500), CGSize(width: 792, height: 612)]
    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdfrecorder-multi-controller-\(UUID().uuidString)")
        workspace = root; support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sources = ["Biology.pdf", "Statistics.pdf", "Speaking Lab.pdf"].map { root.appendingPathComponent($0) }
        bytes = [Self.pdf(sizes: [.init(width: 612, height: 792), .init(width: 612, height: 792)], firstPage: 1),
                 Self.pdf(sizes: [.init(width: 960, height: 540)], firstPage: 3),
                 Self.pdf(sizes: [.init(width: 500, height: 700), .init(width: 900, height: 500), .init(width: 612, height: 792)], firstPage: 4, rotateLast: true)]
        for (url, data) in zip(sources, bytes) { try data.write(to: url) }
    }
    func remove() { try? FileManager.default.removeItem(at: workspace) }
    private static func pdf(sizes: [CGSize], firstPage: Int, rotateLast: Bool = false) -> Data {
        let data = NSMutableData(); var box = CGRect(origin: .zero, size: sizes[0])
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for (index, size) in sizes.enumerated() {
            var bounds = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox: NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
            let label = CFAttributedStringCreate(nil, "GLOBAL PAGE \(firstPage + index)" as CFString, attributes)!
            context.textPosition = CGPoint(x: 48, y: size.height - 80)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            context.endPDFPage()
        }
        context.closePDF()
        let pdf = PDFDocument(data: data as Data)!
        if rotateLast { pdf.page(at: pdf.pageCount - 1)?.rotation = 90 }
        return pdf.dataRepresentation()!
    }
}
