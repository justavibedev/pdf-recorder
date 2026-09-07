import XCTest
import AVFoundation
@testable import PDFRecorderCore

final class PresentationTests: XCTestCase {
    func testV1ProjectsUpgradeWithoutLosingTakesOrRewritingOnRead() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.pdf")
        try fixturePDF().dataRepresentation()!.write(to: source)
        let project = root.appendingPathComponent("legacy.pdfrecorder")
        var manifest = try ProjectStore.create(at: project, source: source, title: "Legacy", pageCount: 3)
        let take = Take(duration: 0.2)
        try writeAudio(at: ProjectStore.prepare(take, at: project), duration: 0.2)
        manifest = try ProjectStore.commit(take, events: [], page: 1, manifest: manifest, at: project)
        manifest.version = 1
        try ProjectStore.save(manifest, at: project)
        let original = try Data(contentsOf: project.appendingPathComponent("manifest.json"))
        var upgraded = try ProjectStore.load(at: project)
        XCTAssertEqual(upgraded.version, 4)
        XCTAssertEqual(upgraded.pages[1].selectedTake?.id, take.id)
        XCTAssertNil(upgraded.pages[1].notes)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("manifest.json")), original)
        upgraded.pages[1].notes = "Explain the proof"
        upgraded.pages[1].bookmarked = true
        upgraded.pages[1].targetSeconds = 90
        try ProjectStore.save(upgraded, at: project)
        XCTAssertEqual(try ProjectStore.load(at: project), upgraded)
    }
    func testSearchMatchesTitlesNotesAndPDFTextWithFilters() {
        var manifest = ProjectManifest(title: "Biology", pageCount: 3)
        manifest.pages[0].title = "Café introduction"
        manifest.pages[1].notes = "Explain mitochondria"
        manifest.pages[1].bookmarked = true
        manifest.pages[2].add(Take(duration: 30))
        let text = ["", "", "Cell division"]
        XCTAssertEqual(PresentationTools.matchingPages(in: manifest, query: "CAFE", filter: .all, pageText: text), [0])
        XCTAssertEqual(PresentationTools.matchingPages(in: manifest, query: "mitochondria", filter: .bookmarks, pageText: text), [1])
        XCTAssertEqual(PresentationTools.matchingPages(in: manifest, query: "cell", filter: .recorded, pageText: text), [2])
        XCTAssertEqual(PresentationTools.matchingPages(in: manifest, query: "", filter: .unfinished, pageText: text), [0, 1])
        XCTAssertEqual(PresentationTools.matchingPages(in: manifest, query: "", filter: .all, pageText: []), [0, 1, 2])
        XCTAssertTrue(PresentationTools.matchingPages(in: manifest, query: "cell", filter: .bookmarks, pageText: text).isEmpty)
    }
    func testExportExclusionsKeepTheOriginalTakes() {
        var manifest = ProjectManifest(title: "Talk", pageCount: 3)
        manifest.pages[0].add(Take(duration: 10)); manifest.pages[1].add(Take(duration: 20))
        manifest.pages[0].includedInExport = false
        XCTAssertEqual(manifest.exportTakes.map(\.page), [1])
        XCTAssertEqual(manifest.selectedTakes.map(\.page), [0, 1])
        manifest.pages[0].includedInExport = true
        XCTAssertEqual(manifest.exportTakes.map(\.page), [0, 1])
    }
    func testNextUnrecordedWrapsAndStopsAtCompletion() {
        var manifest = ProjectManifest(title: "Talk", pageCount: 3)
        manifest.pages[1].add(Take(duration: 1))
        XCTAssertEqual(PresentationTools.nextUnrecorded(in: manifest, after: 1), 2)
        XCTAssertEqual(PresentationTools.nextUnrecorded(in: manifest, after: 2), 0)
        manifest.pages[0].add(Take(duration: 1)); manifest.pages[2].add(Take(duration: 1))
        XCTAssertNil(PresentationTools.nextUnrecorded(in: manifest, after: 0))
    }
    func testNotesExportAndPlaybackSkipBoundaries() {
        var manifest = ProjectManifest(title: "Class", pageCount: 2)
        manifest.pages[0].title = "Opening"; manifest.pages[0].notes = "Remember the example."
        manifest.pages[0].targetSeconds = 60
        let markdown = PresentationTools.notesMarkdown(manifest)
        XCTAssertTrue(markdown.contains("## 1. Opening"))
        XCTAssertTrue(markdown.contains("Remember the example."))
        XCTAssertTrue(markdown.contains("Target: 60 seconds"))
        XCTAssertTrue(markdown.contains("## 2. Page 2"))
        XCTAssertEqual(PresentationTools.clampedPlaybackPosition(5, skipping: -10, duration: 30), 0)
        XCTAssertEqual(PresentationTools.clampedPlaybackPosition(25, skipping: 10, duration: 30), 30)
    }
    func testCancellingCountdownCannotReachCaptureStep() async throws {
        let (signal, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { continuation.finish() }
            try await RecordingCountdown.run(seconds: 5) { continuation.yield($0) }
            return "capture would start here"
        }
        for await value in signal { XCTAssertEqual(value, 5); break }
        task.cancel()
        do { _ = try await task.value; XCTFail("Countdown must not complete after cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testAudioStudyExportHasOnlyAACAndCorrectDuration() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var items: [ExportItem] = []
        for page in 0..<2 {
            let audio = root.appendingPathComponent("\(page).caf")
            try writeAudio(at: audio, duration: 0.4)
            items.append(ExportItem(page: page, take: Take(duration: 0.4), events: [], audioURL: audio))
        }
        let output = root.appendingPathComponent("study.m4a")
        try await AudioExporter.export(items: items, to: output, progress: { _ in })
        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let length = try await asset.load(.duration)
        XCTAssertEqual(audio.count, 1); XCTAssertTrue(video.isEmpty)
        XCTAssertEqual(length.seconds, 0.8, accuracy: 0.05)
        let descriptions = try await audio[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(descriptions[0]), kAudioFormatMPEG4AAC)
    }
    func testAudioExportFailureAndCancellationPreserveExistingFile() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.m4a")
        let original = Data("Keep the earlier export".utf8); try original.write(to: output)
        let missing = ExportItem(page: 0, take: Take(duration: 1), events: [], audioURL: root.appendingPathComponent("missing.caf"))
        do { try await AudioExporter.export(items: [missing], to: output, progress: { _ in }); XCTFail("Missing audio must fail") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: output), original)
        let audio = root.appendingPathComponent("synthetic.caf"); try writeAudio(at: audio, duration: 0.4)
        let task = Task {
            // Cancel this task deterministically before handing it to the exporter.
            withUnsafeCurrentTask { $0?.cancel() }
            try await AudioExporter.export(items: [.init(page: 0, take: Take(duration: 0.4), events: [], audioURL: audio)], to: output, progress: { _ in })
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".pdfrecorder-") })
    }
}
