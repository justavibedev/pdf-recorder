import XCTest
import PDFKit
import AVFoundation
import PDFRecorderCore
@testable import PDFRecorderAppSupport

/// Preparation is canceled synchronously before its main-actor task can construct or play a transport.
final class PlaybackPreparationTests: XCTestCase {
    @MainActor func testCancellingImmediateListenRestoresWaveformAndScrubbing() async throws {
        let fixture = try PreparationFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.root.appendingPathComponent("support"), connectDevices: false)
        model.open(fixture.project)
        let take = try XCTUnwrap(model.selectedTake)
        XCTAssertTrue(model.reviewLoading)
        let oldReviewGeneration = model.reviewGeneration
        model.startPlayback(page: 0, take: take, from: take.playbackStart)
        let preparation = model.playbackTask
        XCTAssertEqual(model.mode, .loadingPlayback)
        XCTAssertNotEqual(model.reviewGeneration, oldReviewGeneration, "An obsolete review reader must not publish errors after preparation takes over")
        model.stopPlayback()
        await preparation?.value
        await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        XCTAssertEqual(model.mode, .idle)
        XCTAssertFalse(model.reviewLoading)
        XCTAssertNotNil(model.waveform)
        XCTAssertNotNil(model.timeline)
        XCTAssertNil(model.player)
        XCTAssertNil(model.errorMessage)
        model.seek(to: 0.2)
        XCTAssertEqual(model.time, 0.2, accuracy: 0.001)
        XCTAssertEqual(model.scene.pointer, Point(0.3, 0.7))
        XCTAssertTrue(model.inputs.isEmpty)
        XCTAssertEqual(model.microphone.snapshot.time, 0)
        try await model.playbackAudioCache.removeAll()
    }

    @MainActor func testPreparationFailureDoesNotLeaveReviewStuckLoading() async throws {
        let fixture = try PreparationFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.root.appendingPathComponent("support"), connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        let take = try XCTUnwrap(model.selectedTake)
        // An unavailable source makes preparation fail before any playback transport exists.
        try FileManager.default.removeItem(at: ProjectStore.location(take.audioPath, in: fixture.project))
        model.reviewLoading = true
        model.startPlayback(page: 0, take: take, from: 0)
        await model.playbackTask?.value
        XCTAssertEqual(model.mode, .idle)
        XCTAssertFalse(model.reviewLoading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.player)
        XCTAssertNotNil(model.timeline, "Previously readable interaction data stays usable after an audio preparation failure")
        model.seek(to: 0.2)
        XCTAssertEqual(model.scene.pointer, Point(0.3, 0.7))
        try await model.playbackAudioCache.removeAll()
    }
}

private struct PreparationFixture {
    let root: URL
    let project: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pdfrecorder-preparation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        project = root.appendingPathComponent("Test.pdfrecorder")
        let source = root.appendingPathComponent("source.pdf")
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.endPDFPage(); context.closePDF(); try (data as Data).write(to: source)
        let manifest = try ProjectStore.create(at: project, source: source, title: "Preparation", pageCount: 1)
        let take = Take(duration: 0.4)
        let audio = try ProjectStore.prepare(take, at: project)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 8_000)) * 0.05 }
        try file.write(from: buffer)
        _ = try ProjectStore.commit(take, events: [.init(time: 0.1, action: .pointer(Point(0.3, 0.7)))], page: 0, manifest: manifest, at: project)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
