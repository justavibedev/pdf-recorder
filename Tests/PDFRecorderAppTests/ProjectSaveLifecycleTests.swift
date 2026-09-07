import XCTest
import PDFKit
import PDFRecorderCore
@testable import PDFRecorderAppSupport

final class ProjectSaveLifecycleTests: XCTestCase {
    @MainActor func testSaveWaitsForCancelledOCRBeforeCopyingCacheAndDeletingRecovery() async throws {
        let fixture = try SaveLifecycleFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs([fixture.source])
        let original = try XCTUnwrap(model.projectURL)
        XCTAssertTrue(model.isRecoveryProject)
        let destination = fixture.root.appendingPathComponent("Saved.pdfrecorder")
        let gate = SaveOCRGate()
        let marker = Data("last completed OCR write".utf8)
        let worker = Task {
            await gate.hold()
            // Simulate an already-running cache write that finishes after cancellation.
            let cache = original.appendingPathComponent("reading")
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? marker.write(to: cache.appendingPathComponent("completion.marker"), options: .atomic)
        }
        model.ocrTask = worker; model.ocrProgress = 0.5
        await gate.waitUntilHeld()
        let saving = Task { try await model.saveProjectCopy(to: destination) }
        await waitUntilSaving(model)
        XCTAssertEqual(model.mode, .savingProject)
        XCTAssertFalse(model.canNavigate); XCTAssertFalse(model.canDraw)
        XCTAssertEqual(model.projectURL, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Copy must wait until the OCR writer has exited")
        XCTAssertTrue(worker.isCancelled)
        XCTAssertNil(model.ocrProgress); XCTAssertNil(model.ocrTask)
        model.updatePage { $0.notes = "Must not mutate during Save As" }
        model.showLibrary()
        XCTAssertNotNil(model.manifest); XCTAssertNil(model.page?.notes)
        await gate.release()
        try await saving.value
        defer { model.reviewTask?.cancel(); model.searchTask?.cancel() }
        XCTAssertEqual(model.mode, .idle)
        XCTAssertEqual(model.projectURL, destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("reading/completion.marker")), marker)
        XCTAssertNotNil(model.pdfPage(at: 0)); XCTAssertNotNil(model.artwork)
        XCTAssertEqual(try ProjectStore.load(at: destination), model.manifest)
        XCTAssertEqual(model.microphone.snapshot.time, 0); XCTAssertNil(model.player)
    }

    @MainActor func testCancelledSaveWaitsForOCRAndPreservesOriginalProject() async throws {
        let fixture = try SaveLifecycleFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs([fixture.source])
        let original = try XCTUnwrap(model.projectURL), before = try XCTUnwrap(model.manifest)
        let destination = fixture.root.appendingPathComponent("Cancelled.pdfrecorder")
        let gate = SaveOCRGate()
        let worker = Task { await gate.hold() }
        model.ocrTask = worker; model.ocrProgress = 0.25
        await gate.waitUntilHeld()
        let saving = Task { try await model.saveProjectCopy(to: destination) }
        await waitUntilSaving(model)
        saving.cancel()
        XCTAssertEqual(model.mode, .savingProject, "Cancellation cannot release the transition lock while OCR still owns the source")
        await gate.release()
        do { try await saving.value; XCTFail("Expected cancelled Save As") }
        catch is CancellationError { }
        defer { model.reviewTask?.cancel(); model.searchTask?.cancel() }
        XCTAssertEqual(model.mode, .idle); XCTAssertNil(model.ocrTask); XCTAssertNil(model.ocrProgress)
        XCTAssertEqual(model.projectURL, original)
        XCTAssertEqual(try ProjectStore.load(at: original), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotNil(model.artwork)
    }

    @MainActor func testFailedSaveKeepsUnsavedMetadataAndReleasesTransitionLock() async throws {
        let fixture = try SaveLifecycleFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs([fixture.source])
        let original = try XCTUnwrap(model.projectURL)
        model.updatePage { $0.notes = "New notes must survive a failed Save As" }
        let destination = original.appendingPathComponent("Nested.pdfrecorder")
        do { try await model.saveProjectCopy(to: destination); XCTFail("Nested destination should fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        defer { model.reviewTask?.cancel(); model.searchTask?.cancel(); model.metadataSaveTask?.cancel() }
        XCTAssertEqual(model.mode, .idle)
        XCTAssertEqual(model.projectURL, original)
        XCTAssertTrue(model.hasUnsavedMetadata)
        XCTAssertEqual(model.page?.notes, "New notes must survive a failed Save As")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(model.flushMetadata())
        XCTAssertEqual(try ProjectStore.load(at: original).pages[0].notes, model.page?.notes)
    }

    @MainActor func testOCRCompletionOnChangedProjectPathAlwaysClearsBusyState() async throws {
        let fixture = try SaveLifecycleFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.openURLs([fixture.source])
        model.startOCR()
        let worker = try XCTUnwrap(model.ocrTask)
        // Change the path before the queued OCR task resumes on the main actor.
        model.projectURL = fixture.root.appendingPathComponent("Another.pdfrecorder")
        await worker.value
        XCTAssertNil(model.ocrTask)
        XCTAssertNil(model.ocrProgress)
        XCTAssertTrue(model.ocrPages.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.microphone.snapshot.time, 0); XCTAssertNil(model.player)
    }

    @MainActor private func waitUntilSaving(_ model: AppModel) async {
        for _ in 0..<100 where model.mode != .savingProject { await Task.yield() }
    }
}

/// A deterministic in-flight cache writer; cancellation does not skip its final I/O.
private actor SaveOCRGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        for observer in observers { observer.resume() }; observers.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { holdContinuation?.resume(); holdContinuation = nil }
}

private struct SaveLifecycleFixture {
    let root: URL, support: URL, source: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pdfrecorder-save-lifecycle-\(UUID().uuidString)")
        support = root.appendingPathComponent("support"); source = root.appendingPathComponent("Source.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: source)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
