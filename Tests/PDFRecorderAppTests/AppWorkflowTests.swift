import XCTest
import AppKit
import PDFKit
import AVFoundation
import PDFRecorderCore
@testable import PDFRecorderAppSupport

/// Headless controller checks. No NSApplication, windows, microphones, or audio playback are started.
final class AppWorkflowTests: XCTestCase {
    @MainActor func testImportingPDFCreatesPortableRecoveryProjectWithoutTouchingSource() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.source)
        defer { model.reviewTask?.cancel(); model.metadataSaveTask?.cancel() }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.manifest?.pages.count, 3)
        XCTAssertTrue(model.manifest?.selectedTakes.isEmpty ?? false)
        XCTAssertTrue(model.isRecoveryProject)
        let project = try XCTUnwrap(model.projectURL)
        XCTAssertTrue(project.path.hasPrefix(fixture.support.path + "/Recovery/"))
        model.updatePage { $0.notes = "New student notes" }
        XCTAssertTrue(model.flushMetadata())
        XCTAssertEqual(try ProjectStore.load(at: project).pages[0].notes, "New student notes")
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("source.pdf")), fixture.originalPDF)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.originalPDF)
        XCTAssertTrue(model.inputs.isEmpty)
        XCTAssertNil(model.player)
    }

    @MainActor func testOpeningProjectRetainsPageMetadataAndOriginalPDF() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project)
        await model.reviewTask?.value
        defer { model.reviewTask?.cancel(); model.metadataSaveTask?.cancel() }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.manifest?.pages[0].title, "First explanation")
        XCTAssertEqual(model.manifest?.pages[0].notes, "Private speaker notes")
        XCTAssertEqual(model.manifest?.pages[0].targetSeconds, 90)
        XCTAssertEqual(model.manifest?.pages[1].bookmarked, true)
        XCTAssertEqual(model.manifest?.pages[1].includedInExport, false)
        XCTAssertEqual(model.pdf?.pageCount, 3)
        XCTAssertTrue(model.inputs.isEmpty)
        XCTAssertEqual(model.mode, .idle)
        XCTAssertNil(model.player)
        XCTAssertEqual(model.microphone.snapshot.time, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.originalPDF)
        XCTAssertEqual(try Data(contentsOf: fixture.project.appendingPathComponent("source.pdf")), fixture.originalPDF)
    }

    @MainActor func testAuditionAndABComparisonKeepExportChoiceUntilExplicitUse() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        let original = try XCTUnwrap(model.page?.takes.first), retake = try XCTUnwrap(model.page?.takes.last)
        XCTAssertEqual(model.page?.selectedTakeID, retake.id)
        model.chooseTake(original); await model.reviewTask?.value
        XCTAssertEqual(model.selectedTakeID, original.id)
        XCTAssertEqual(model.page?.selectedTakeID, retake.id)
        XCTAssertEqual(try ProjectStore.load(at: fixture.project).pages[0].selectedTakeID, retake.id)

        model.time = 4; model.comparisonTakeID = retake.id
        model.compareTake(); await model.reviewTask?.value
        XCTAssertEqual(model.selectedTakeID, retake.id)
        XCTAssertEqual(model.comparisonTakeID, original.id)
        XCTAssertEqual(model.time, 4, accuracy: 0.001)
        XCTAssertEqual(model.page?.selectedTakeID, retake.id)
        model.useTake(original)
        XCTAssertEqual(model.selectedTakeID, retake.id, "Using a take for export must not replace the take being reviewed")
        XCTAssertEqual(model.page?.selectedTakeID, original.id)
        XCTAssertEqual(try ProjectStore.load(at: fixture.project).pages[0].selectedTakeID, original.id)
        XCTAssertNil(model.player, "Audition selection alone must not start audio")
    }

    @MainActor func testTrimmingClampsPlayheadDisablesInvalidLoopAndKeepsSourceAndMarkers() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        let take = try XCTUnwrap(model.selectedTake)
        let audioURL = try ProjectStore.location(take.audioPath, in: fixture.project)
        let sourceAudio = try Data(contentsOf: audioURL)
        model.time = 2; model.addReviewMarker("Keep source context")
        model.time = 5; model.addReviewMarker("Check equation")
        model.updateTake { $0.loopRange = TakeLoopRange(start: 1, end: 6) }
        model.loopEnabled = true
        model.time = 1
        model.updateTake { $0.trimStart = 3; $0.trimEnd = 7 }
        await model.reviewTask?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.time, 3, accuracy: 0.001)
        XCTAssertNil(model.selectedTake?.loopRange)
        XCTAssertFalse(model.loopEnabled)
        XCTAssertEqual(model.selectedTake?.reviewMarkers?.map(\.time), [2, 5], "Source-time markers survive nondestructive trimming")
        model.seek(to: 100); XCTAssertEqual(model.time, 7, accuracy: 0.001)
        model.seek(to: 0); XCTAssertEqual(model.time, 3, accuracy: 0.001)
        XCTAssertEqual(model.scene.strokes.count, 1, "A stroke drawn before the trim remains visible in the retained scene")
        let valid = model.selectedTake
        model.updateTake { $0.trimStart = 6.99; $0.trimEnd = 7 }
        XCTAssertEqual(model.selectedTake, valid, "A rejected trim must leave the saved take intact")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: audioURL), sourceAudio)
        let saved = try ProjectStore.load(at: fixture.project).pages[0].selectedTake
        XCTAssertEqual(saved?.trimStart, 3); XCTAssertEqual(saved?.trimEnd, 7)
    }

    @MainActor func testAnnotationUndoRedoAndClearAreGroupedWithoutCapture() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        model.scene = Scene(); model.groupedUndoActions = []; model.redoActions = []
        let line = Stroke(tool: .arrow, color: "blue", width: 0.005, points: [Point(0.1, 0.2), Point(0.8, 0.2)], opacity: 0.5, shape: .arrow)
        let label = Stroke(tool: .text, color: "red", width: 0.02, points: [Point(0.2, 0.6)], opacity: 1, shape: .text, text: "Key idea")
        model.apply(.beginStroke(line)); model.finishedStroke(line.id)
        model.apply(.beginStroke(label)); model.finishedStroke(label.id)
        XCTAssertEqual(model.scene.strokes, [line, label])
        model.undo(); XCTAssertEqual(model.scene.strokes, [line])
        model.redo(); XCTAssertEqual(model.scene.strokes, [line, label])
        model.erase(label); XCTAssertEqual(model.scene.strokes, [line])
        model.undo(); XCTAssertEqual(model.scene.strokes, [line, label])
        model.clearMarks(); XCTAssertTrue(model.scene.strokes.isEmpty)
        model.undo(); XCTAssertEqual(model.scene.strokes, [line, label], "Clear Marks should undo as one action")
        model.redo(); XCTAssertTrue(model.scene.strokes.isEmpty)
        model.undo(); model.apply(.beginStroke(Stroke(tool: .pen, color: "green", width: 0.003, points: [Point(0.4, 0.4)])))
        model.finishedStroke(model.scene.strokes.last!.id)
        XCTAssertTrue(model.redoActions.isEmpty, "A new mark clears the old redo branch")
        XCTAssertTrue(model.events.isEmpty)
        XCTAssertEqual(model.microphone.snapshot.time, 0)
        XCTAssertEqual(model.mode, .idle)
    }

    @MainActor func testErasingLowerLayersAndUndoingClearRetainsAnnotationOrder() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        model.scene = Scene(); model.groupedUndoActions = []; model.redoActions = []
        let lower = Stroke(tool: .pen, color: "red", width: 0.03, points: [Point(0.1, 0.5), Point(0.9, 0.5)])
        let middle = Stroke(tool: .pen, color: "blue", width: 0.03, points: [Point(0.5, 0.1), Point(0.5, 0.9)])
        let upper = Stroke(tool: .pen, color: "green", width: 0.03, points: [Point(0.2, 0.8), Point(0.8, 0.8)])
        let ordered = [lower, middle, upper]
        for stroke in ordered { model.apply(.beginStroke(stroke)); model.finishedStroke(stroke.id) }
        model.erase(middle)
        XCTAssertEqual(model.scene.strokes, [lower, upper])
        XCTAssertEqual(model.groupedUndoActions.last, [.restoreStroke(middle, index: 1)])
        model.undo(); XCTAssertEqual(model.scene.strokes, ordered)
        model.redo(); XCTAssertEqual(model.scene.strokes, [lower, upper])
        model.undo(); XCTAssertEqual(model.scene.strokes, ordered)

        model.erase(lower); model.erase(middle)
        XCTAssertEqual(model.scene.strokes, [upper])
        model.undo(); XCTAssertEqual(model.scene.strokes, [middle, upper])
        model.undo(); XCTAssertEqual(model.scene.strokes, ordered)
        model.redo(); XCTAssertEqual(model.scene.strokes, [middle, upper])
        model.redo(); XCTAssertEqual(model.scene.strokes, [upper])
        model.undo(); model.undo(); XCTAssertEqual(model.scene.strokes, ordered)

        model.clearMarks(); XCTAssertTrue(model.scene.strokes.isEmpty)
        for _ in 0..<3 {
            model.undo(); XCTAssertEqual(model.scene.strokes, ordered)
            model.redo(); XCTAssertTrue(model.scene.strokes.isEmpty)
        }
        model.undo(); XCTAssertEqual(model.scene.strokes, ordered)
        XCTAssertTrue(model.events.isEmpty, "Headless annotation review never starts a recording")
        XCTAssertEqual(model.mode, .idle)
    }

    @MainActor func testPreferencesPinnedProjectsAndLastViewportReopenFromIsolatedStorage() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        model.inputID = "test-device-preference-only"; model.countdownSeconds = 5
        model.playbackRate = 1.5; model.notesFontSize = 24; model.hideInspector = true
        model.focusMode = true; model.showNotes = true; model.largeControls = true
        model.navigate(to: 2); await model.reviewTask?.value
        let viewport = Viewport(zoom: 2, offset: Point(0.15, -0.2))
        model.scene.viewport = viewport; model.rememberWorkspace()
        model.togglePin(try XCTUnwrap(model.recentProjects.first))
        let reopened = AppModel(storageRoot: fixture.support, connectDevices: false)
        defer { model.reviewTask?.cancel(); reopened.reviewTask?.cancel() }
        XCTAssertEqual(reopened.supportRoot, fixture.support)
        XCTAssertEqual(reopened.inputID, "test-device-preference-only")
        XCTAssertEqual(reopened.countdownSeconds, 5)
        XCTAssertEqual(reopened.playbackRate, 1.5)
        XCTAssertEqual(reopened.notesFontSize, 24)
        XCTAssertTrue(reopened.hideInspector); XCTAssertTrue(reopened.focusMode)
        XCTAssertTrue(reopened.showNotes); XCTAssertTrue(reopened.largeControls)
        XCTAssertEqual(reopened.recentProjects.first?.pinned, true)
        reopened.open(fixture.project); await reopened.reviewTask?.value
        XCTAssertEqual(reopened.pageIndex, 2)
        XCTAssertEqual(reopened.scene.viewport, viewport)
        XCTAssertTrue(reopened.inputs.isEmpty)
        XCTAssertNil(reopened.player)
        reopened.navigate(to: 0); await reopened.reviewTask?.value
        let recordedPageViewport = Viewport(zoom: 3, offset: Point(-0.25, 0.12))
        reopened.scene.viewport = recordedPageViewport; reopened.rememberWorkspace()
        let recordedPage = AppModel(storageRoot: fixture.support, connectDevices: false)
        defer { recordedPage.reviewTask?.cancel() }
        recordedPage.open(fixture.project); await recordedPage.reviewTask?.value
        XCTAssertEqual(recordedPage.pageIndex, 0)
        XCTAssertEqual(recordedPage.scene.viewport, recordedPageViewport, "Background waveform loading must not overwrite the restored workspace viewport")
    }

    @MainActor func testTakeDeletionCanBeUndoneWithoutLosingAudio() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        defer { model.reviewTask?.cancel() }
        let take = try XCTUnwrap(model.selectedTake)
        let audio = try ProjectStore.location(take.audioPath, in: fixture.project), bytes = try Data(contentsOf: audio)
        model.deleteTake(take); await model.reviewTask?.value
        XCTAssertFalse(model.page?.takes.contains(where: { $0.id == take.id }) ?? true)
        XCTAssertEqual(model.lastDeletedTake, take.id)
        XCTAssertEqual(try ProjectRecovery.trash(at: fixture.project).map(\.id), [take.id])
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        model.restoreDeletedTake(take.id); await model.reviewTask?.value
        XCTAssertTrue(model.page?.takes.contains(where: { $0.id == take.id }) ?? false)
        XCTAssertNil(model.lastDeletedTake)
        XCTAssertTrue(try ProjectRecovery.trash(at: fixture.project).isEmpty)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testSaveCopyRescuesUnsavedNotesWhenOriginalProjectIsReadOnly() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        defer { model.reviewTask?.cancel(); model.metadataSaveTask?.cancel() }
        model.updatePage { $0.notes = "Unsaved notes rescued to another disk"; $0.title = "Rescued explanation" }
        model.metadataSaveTask?.cancel()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.project.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.project.path) }
        XCTAssertFalse(model.flushMetadata(), "This fixture must reject saving into its read-only package")
        XCTAssertTrue(model.hasUnsavedMetadata)
        let destination = fixture.workspace.appendingPathComponent("Rescued.pdfrecorder")
        try ProjectStore.saveCopy(from: fixture.project, to: destination, manifest: XCTUnwrap(model.manifest))
        let rescued = try ProjectStore.load(at: destination)
        XCTAssertEqual(rescued.pages[0].notes, "Unsaved notes rescued to another disk")
        XCTAssertEqual(rescued.pages[0].title, "Rescued explanation")
        XCTAssertEqual(rescued.pages[0].takes.count, 2)
        XCTAssertEqual(try ProjectStore.load(at: fixture.project).pages[0].notes, "Private speaker notes")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.originalPDF)
    }

    @MainActor func testPresentationPauseResumeKeepsQueueAndExactTrimmedPosition() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        model.updateTake { $0.trimStart = 2; $0.trimEnd = 8 }; await model.reviewTask?.value
        defer { model.stopPlayback(); model.reviewTask?.cancel() }
        let originalID = model.selectedTakeID
        let queued = [Take(duration: 4), Take(duration: 6)]
        let fake = FakePlaybackTransport(currentTime: 1.25, isPlaying: true)
        model.player = fake; model.playbackIsPresentation = true
        model.playbackQueue = [(1, queued[0]), (2, queued[1])]
        model.mode = .playing
        model.play(all: true)
        XCTAssertEqual(model.mode, .idle)
        XCTAssertTrue(model.playbackPaused)
        XCTAssertEqual(model.time, 3.25, accuracy: 0.0001, "Pause samples the transport clock instead of the most recent timer tick")
        XCTAssertEqual(model.playbackQueue.map(\.take.id), queued.map(\.id))
        XCTAssertEqual(fake.pauseCount, 1)
        model.play(all: true)
        XCTAssertEqual(model.mode, .playing)
        XCTAssertFalse(model.playbackPaused)
        XCTAssertEqual(fake.playCount, 1)
        XCTAssertEqual(fake.currentTime, 1.25, accuracy: 0.0001)
        XCTAssertEqual(model.selectedTakeID, originalID)
        XCTAssertEqual(model.playbackQueue.map(\.take.id), queued.map(\.id), "Resume must retain the remaining presentation")
        fake.currentTime = 1.75; model.tick()
        XCTAssertEqual(model.time, 3.75, accuracy: 0.0001)

        fake.currentTime = 6; model.play(all: true)
        XCTAssertEqual(model.time, 8, accuracy: 0.0001)
        model.play(all: true)
        XCTAssertEqual(model.time, 2, accuracy: 0.0001, "Resuming an ended trimmed clip restarts the current page")
        XCTAssertEqual(fake.currentTime, 0)
        XCTAssertEqual(model.selectedTakeID, originalID)
        XCTAssertEqual(model.playbackQueue.map(\.take.id), queued.map(\.id))

        model.play(all: true); fake.playSucceeds = false; model.play(all: true)
        XCTAssertEqual(model.mode, .idle)
        XCTAssertNil(model.player)
        XCTAssertTrue(model.playbackQueue.isEmpty)
        XCTAssertEqual(model.errorMessage, "Playback could not resume. Try playing the take again.")
        XCTAssertEqual(model.microphone.snapshot.time, 0)
    }

    @MainActor func testABLoopUsesSourceTimesAndRestartsEndedTransportWithoutAudioDevice() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        model.open(fixture.project); await model.reviewTask?.value
        model.updateTake { $0.trimStart = 2; $0.trimEnd = 8; $0.loopRange = TakeLoopRange(start: 3, end: 5) }
        await model.reviewTask?.value
        defer { model.stopPlayback(); model.reviewTask?.cancel() }
        let fake = FakePlaybackTransport(currentTime: 3, isPlaying: true)
        model.player = fake; model.loopEnabled = true; model.mode = .playing
        model.tick()
        XCTAssertEqual(model.time, 3, accuracy: 0.0001)
        XCTAssertEqual(fake.currentTime, 1, accuracy: 0.0001)
        XCTAssertEqual(fake.playCount, 0, "Looping an active transport seeks without restarting its audio device")
        fake.currentTime = 6; fake.isPlaying = false
        model.tick()
        XCTAssertEqual(model.mode, .playing)
        XCTAssertEqual(model.time, 3, accuracy: 0.0001)
        XCTAssertEqual(fake.currentTime, 1, accuracy: 0.0001)
        XCTAssertEqual(fake.playCount, 1)
        XCTAssertTrue(fake.isPlaying)
        model.loopEnabled = false; fake.currentTime = 6; fake.isPlaying = false
        model.tick()
        XCTAssertEqual(model.time, 8, accuracy: 0.0001)
        XCTAssertEqual(model.mode, .idle)
        XCTAssertNil(model.player)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testSleepAssertionBalancesAcrossActiveAndIdleModesWithoutCapture() async throws {
        let fixture = try WorkflowFixture(); defer { fixture.remove() }
        let model = AppModel(storageRoot: fixture.support, connectDevices: false)
        defer { model.mode = .idle }
        XCTAssertNil(model.activity)
        for mode in [AppModel.Mode.starting, .recording, .paused, .stopping, .exporting, .checkingMicrophone] {
            model.mode = mode
            let activity = try XCTUnwrap(model.activity)
            model.updateActivity()
            XCTAssertTrue(model.activity === activity, "Repeated updates must not accumulate sleep assertions")
        }
        model.mode = .idle
        XCTAssertNil(model.activity)
        XCTAssertNil(model.timer)
        XCTAssertEqual(model.microphone.snapshot.time, 0)
        XCTAssertTrue(model.inputs.isEmpty)
        XCTAssertTrue(model.events.isEmpty)
    }

    func testMicrophoneFeedbackClassifiesSyntheticLevelsWithoutCapture() {
        let waiting = MicrophoneRecorder.Snapshot(time: 0.5, level: 0, rmsDB: -100, peak: 0)
        let silent = MicrophoneRecorder.Snapshot(time: 2, level: 0, rmsDB: -80, peak: 0)
        let quiet = MicrophoneRecorder.Snapshot(time: 2, level: 0.05, rmsDB: -40, peak: 0.05)
        let healthy = MicrophoneRecorder.Snapshot(time: 2, level: 0.25, rmsDB: -20, peak: 0.6)
        let clipping = MicrophoneRecorder.Snapshot(time: 2, level: 1, rmsDB: -1, peak: 1)
        XCTAssertTrue(waiting.feedback.hasPrefix("Speak normally"))
        XCTAssertTrue(silent.feedback.hasPrefix("No speech detected"))
        XCTAssertTrue(quiet.feedback.hasPrefix("Too quiet"))
        XCTAssertTrue(healthy.feedback.hasPrefix("Good level"))
        XCTAssertTrue(clipping.feedback.hasPrefix("Clipping"))
    }
}

private final class FakePlaybackTransport: PlaybackTransport {
    var currentTime: TimeInterval
    var rate: Float = 1
    var enableRate = false
    var isPlaying: Bool
    var playSucceeds = true
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    init(currentTime: TimeInterval, isPlaying: Bool) { self.currentTime = currentTime; self.isPlaying = isPlaying }
    @discardableResult func play() -> Bool { playCount += 1; isPlaying = playSucceeds; return playSucceeds }
    func pause() { pauseCount += 1; isPlaying = false }
    func stop() { stopCount += 1; isPlaying = false }
    @discardableResult func prepareToPlay() -> Bool { true }
}

private struct WorkflowFixture {
    let workspace: URL, support: URL, source: URL, project: URL
    let originalPDF: Data
    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-recorder-controller-\(UUID().uuidString)")
        support = workspace.appendingPathComponent("support", isDirectory: true)
        source = workspace.appendingPathComponent("original.pdf")
        project = workspace.appendingPathComponent("Study.pdfrecorder", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        originalPDF = workflowPDF()
        try originalPDF.write(to: source)
        var manifest = try ProjectStore.create(at: project, source: source, title: "Study", pageCount: 3)
        manifest.pages[0].title = "First explanation"; manifest.pages[0].notes = "Private speaker notes"; manifest.pages[0].targetSeconds = 90
        manifest.pages[1].bookmarked = true; manifest.pages[1].includedInExport = false
        for index in 0..<2 {
            var take = Take(duration: 10)
            take.name = index == 0 ? "First version" : "Clearer example"
            try workflowAudio(at: ProjectStore.prepare(take, at: project), seconds: 10)
            let stroke = Stroke(tool: .pen, color: "blue", width: 0.003, points: [Point(0.2, 0.2)])
            let events: [TimedEvent] = [.init(time: 1, action: .beginStroke(stroke)), .init(time: 2, action: .extendStroke(stroke.id, Point(0.8, 0.8)))]
            manifest = try ProjectStore.commit(take, events: events, page: 0, manifest: manifest, at: project)
        }
        try ProjectStore.save(manifest, at: project)
    }
    func remove() {
        // Permission-failure fixtures can leave a read-only staged directory after a failed assertion.
        if let entries = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let url as URL in entries {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true, values?.isSymbolicLink != true {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
            }
        }
        try? FileManager.default.removeItem(at: workspace)
    }
}

private func workflowPDF() -> Data {
    let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for index in 0..<3 {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: CGFloat(index + 1) / 3, alpha: 1))
        context.fill(CGRect(x: 40, y: 60, width: 120, height: 80)); context.endPDFPage()
    }
    context.closePDF(); return data as Data
}

private func workflowAudio(at url: URL, seconds: Int) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
    buffer.frameLength = buffer.frameCapacity
    for index in 0..<8_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 8_000)) * 0.05 }
    for _ in 0..<seconds { try file.write(from: buffer) }
}
