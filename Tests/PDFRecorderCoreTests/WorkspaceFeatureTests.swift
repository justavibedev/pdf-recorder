import XCTest
@testable import PDFRecorderCore

final class WorkspaceFeatureTests: XCTestCase {
    private func project(in temporary: URL, title: String = "Seminar") throws -> (URL, ProjectManifest) {
        let source = temporary.appendingPathComponent("source-original.pdf")
        try XCTUnwrap(fixturePDF().dataRepresentation()).write(to: source)
        let root = temporary.appendingPathComponent("seminar.pdfrecorder")
        return (root, try ProjectStore.create(at: root, source: source, title: title, pageCount: 3))
    }
    private func addTake(page: Int, manifest: ProjectManifest, at root: URL) throws -> (Take, ProjectManifest) {
        var take = Take(duration: 0.2)
        take.createdAt = Date(timeIntervalSince1970: 1_000)
        try writeAudio(at: ProjectStore.prepare(take, at: root), duration: 0.2)
        let events = [TimedEvent(time: 0.1, action: .pointer(Point(0.4, 0.6)))]
        return (take, try ProjectStore.commit(take, events: events, page: page, manifest: manifest, at: root))
    }
    func testPreferencesAndPinnedRecentWorkspaceRoundTrip() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try WorkspaceStore.loadPreferences(at: root), RecorderPreferences())
        var preferences = RecorderPreferences()
        preferences.microphoneID = "test-input-identifier"; preferences.countdown = 5; preferences.playbackRate = 1.5
        preferences.notesFontSize = 23; preferences.hidePages = true; preferences.hideInspector = true
        preferences.showNotes = true; preferences.largeControls = true
        try WorkspaceStore.savePreferences(preferences, at: root)
        XCTAssertEqual(try WorkspaceStore.loadPreferences(at: root), preferences)
        var entries = (0..<34).map { index -> RecentProject in
            var manifest = ProjectManifest(title: "Lecture \(index)", pageCount: 4)
            manifest.pages[0].add(Take(duration: 1))
            var recent = RecentProject(manifest: manifest, url: root.appendingPathComponent("lecture-\(index).pdfrecorder"),
                                       workspace: .init(page: 2, viewport: .init(zoom: 2.5, offset: Point(0.1, -0.2))))
            recent.lastOpened = Date(timeIntervalSince1970: Double(index)); return recent
        }
        entries[0].pinned = true; entries[1].pinned = true
        try WorkspaceStore.saveRecent(entries, at: root)
        let restored = try WorkspaceStore.loadRecent(at: root)
        XCTAssertEqual(restored.count, 32, "Pinned projects are kept in addition to the 30 most recent unpinned projects")
        XCTAssertEqual(restored.prefix(2).map(\.id), [entries[1].id, entries[0].id])
        XCTAssertEqual(restored[2].id, entries[33].id)
        XCTAssertEqual(restored[0].workspace, entries[1].workspace)
        XCTAssertEqual(restored[0].recordedCount, 1)
        XCTAssertEqual(restored[0].path, entries[1].path)
        XCTAssertFalse(restored.contains { $0.id == entries[2].id || $0.id == entries[3].id })
    }
    func testBatchDestinationKeepsImportedTitlesInsideChosenFolder() {
        let parent = URL(fileURLWithPath: "/tmp/Chosen Folder", isDirectory: true)
        for title in ["../../Outside", "/Volumes/Elsewhere", "..", "", "lecture\nnotes:2026", String(repeating: "📚", count: 100)] {
            let url = BatchExport.destination(in: parent, title: title)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, parent.standardizedFileURL.path)
            XCTAssertFalse(url.lastPathComponent.contains("/"))
            XCTAssertFalse(url.lastPathComponent.contains(":"))
            XCTAssertFalse(url.lastPathComponent.contains("\n"))
            XCTAssertLessThan(url.lastPathComponent.utf8.count, 255)
        }
        XCTAssertTrue(BatchExport.destination(in: parent, title: "..").lastPathComponent.hasPrefix("Presentation — Pages "))
    }

    func testExportPageRangesDeduplicateAndValidateBounds() throws {
        XCTAssertEqual(try ExportPageSelection.parse("3-5, 1, 3, 8", pageCount: 8), [0, 2, 3, 4, 7])
        XCTAssertEqual(try ExportPageSelection.parse(" 2 - 2 ", pageCount: 3), [1])
        for value in ["", "0", "-1", "1,", ",1", "4", "3-2", "1-4", "1-2-3", "one", "1.5"] {
            XCTAssertThrowsError(try ExportPageSelection.parse(value, pageCount: 3), "Expected invalid page range: \(value)")
        }
    }
    func testTrashRestorePreservesSourceAndMediaAndPurgeProtectsSnapshots() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let (take, recorded) = try addTake(page: 0, manifest: initial, at: root)
        let sourceURL = root.appendingPathComponent(recorded.sourcePDF)
        let audioURL = try ProjectStore.location(take.audioPath, in: root)
        let eventsURL = try ProjectStore.location(take.eventsPath, in: root)
        let source = try Data(contentsOf: sourceURL), audio = try Data(contentsOf: audioURL), events = try Data(contentsOf: eventsURL)
        XCTAssertThrowsError(try ProjectRecovery.purgeTake(take.id, manifest: recorded, at: root))
        let checkpoint = try ProjectRecovery.snapshot(recorded, reason: "Before cleanup", at: root)
        let deleted = try ProjectRecovery.trashTake(take.id, page: 0, manifest: recorded, at: root)
        XCTAssertTrue(deleted.pages[0].takes.isEmpty)
        XCTAssertEqual(try ProjectRecovery.trash(at: root).map(\.id), [take.id])
        XCTAssertThrowsError(try ProjectRecovery.purgeTake(take.id, manifest: deleted, at: root), "Snapshot still references this recording")
        let restored = try ProjectRecovery.restoreTake(take.id, manifest: deleted, at: root)
        XCTAssertEqual(restored.pages[0].selectedTakeID, take.id)
        XCTAssertTrue(try ProjectRecovery.trash(at: root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: eventsURL), events)
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        let deletedAgain = try ProjectRecovery.trashTake(take.id, page: 0, manifest: restored, at: root)
        try ProjectRecovery.removeSnapshot(checkpoint.id, at: root)
        try ProjectRecovery.purgeTake(take.id, manifest: deletedAgain, at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
    }
    func testSnapshotRestoresMetadataAndSelectionsAndPreservesNewerWork() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let (first, recorded) = try addTake(page: 0, manifest: initial, at: root)
        var baseline = recorded; baseline.pages[0].notes = "Original explanation"
        baseline.pages[0].title = "Opening"; baseline.pages[0].targetSeconds = 42
        try ProjectStore.save(baseline, at: root)
        let snapshot = try ProjectRecovery.snapshot(baseline, reason: "Good draft", at: root)
        let (newer, amended) = try addTake(page: 0, manifest: baseline, at: root)
        var current = amended; current.pages[0].notes = "Revised explanation"
        current.pages[0].takes[1].trimStart = 0.05; try ProjectStore.save(current, at: root)
        let restored = try ProjectRecovery.restoreSnapshot(snapshot, current: current, at: root)
        XCTAssertEqual(restored, baseline)
        XCTAssertEqual(try ProjectStore.load(at: root), baseline)
        XCTAssertEqual(restored.pages[0].selectedTakeID, first.id)
        XCTAssertTrue(try ProjectRecovery.trash(at: root).contains { $0.id == newer.id })
        let automatic = try XCTUnwrap(ProjectRecovery.snapshots(at: root).first { $0.id != snapshot.id })
        XCTAssertEqual(automatic.manifest, current, "Restoring must retain a checkpoint of the newer work")
        XCTAssertThrowsError(try ProjectRecovery.purgeTake(newer.id, manifest: restored, at: root))
        let restoredForward = try ProjectRecovery.restoreSnapshot(automatic, current: restored, at: root)
        XCTAssertEqual(restoredForward.pages[0].selectedTakeID, newer.id)
        XCTAssertEqual(restoredForward.pages[0].notes, "Revised explanation")
        XCTAssertFalse(try ProjectRecovery.trash(at: root).contains { $0.id == newer.id }, "A take restored by a snapshot must leave Trash")
    }
    func testMissingMediaIsolationKeepsHealthyPagesAndRetriesRestoredFiles() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let (healthy, first) = try addTake(page: 0, manifest: initial, at: root)
        let (missing, recorded) = try addTake(page: 1, manifest: first, at: root)
        let missingURL = try ProjectStore.location(missing.audioPath, in: root)
        let data = try Data(contentsOf: missingURL)
        try FileManager.default.removeItem(at: missingURL)
        let isolated = try ProjectRecovery.isolateMissingMedia(recorded, at: root)
        XCTAssertEqual(isolated.pages[0].selectedTakeID, healthy.id)
        XCTAssertTrue(isolated.pages[1].takes.isEmpty)
        XCTAssertEqual(try ProjectRecovery.unavailable(at: root).map(\.id), [missing.id])
        XCTAssertEqual(try ProjectStore.load(at: root), isolated)
        XCTAssertEqual(try ProjectRecovery.retryUnavailable(isolated, at: root), isolated)
        try data.write(to: missingURL)
        let restored = try ProjectRecovery.retryUnavailable(isolated, at: root)
        XCTAssertEqual(restored.pages[1].selectedTakeID, missing.id)
        XCTAssertEqual(restored.pages[0], recorded.pages[0])
        XCTAssertTrue(try ProjectRecovery.unavailable(at: root).isEmpty)
        XCTAssertTrue(try ProjectRecovery.snapshots(at: root).contains { $0.manifest == recorded })
    }
    func testSetAsideRecoveryGuardsPendingTakeAndRestoresReadableJournal() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let take = Take(duration: 0.2)
        try writeAudio(at: ProjectStore.prepare(take, at: root), duration: 0.2)
        let events = [TimedEvent(time: 0.1, action: .pointer(Point(0.5, 0.5)))]
        try ProjectStore.journal(ActiveTake(page: 2, take: take, events: events), at: root)
        try ProjectStore.setAsideActiveTake(at: root)
        let name = try XCTUnwrap(ProjectRecovery.inspect(manifest: initial, at: root).setAsideRecordings.first)
        let kept = try Data(contentsOf: root.appendingPathComponent(name))
        let pending = Data("pending recording remains untouched".utf8)
        try pending.write(to: root.appendingPathComponent("active-take.json"))
        XCTAssertThrowsError(try ProjectRecovery.recoverSetAside(name, manifest: initial, at: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("active-take.json")), pending)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), kept)
        try FileManager.default.removeItem(at: root.appendingPathComponent("active-take.json"))
        let restored = try ProjectRecovery.recoverSetAside(name, manifest: initial, at: root)
        let recovered = try XCTUnwrap(restored.pages[2].selectedTake)
        XCTAssertEqual(recovered.id, take.id); XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(try ProjectStore.events(for: recovered, at: root), events)
        XCTAssertTrue(try ProjectRecovery.inspect(manifest: restored, at: root).setAsideRecordings.isEmpty)
        let invalid = "unfinished-invalid.json"
        let broken = Data("unreadable journal".utf8); try broken.write(to: root.appendingPathComponent(invalid))
        XCTAssertThrowsError(try ProjectRecovery.recoverSetAside(invalid, manifest: restored, at: root))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(invalid)), broken, "Failed recovery returns the journal to its original name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active-take.json").path))
    }
    func testBatchExportFailureAndCancellationPublishNothingAndKeepPriorFiles() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let prior = root.appendingPathComponent("prior.mp4"), priorBytes = Data("Existing export".utf8)
        try priorBytes.write(to: prior)
        let failed = root.appendingPathComponent("failed")
        do {
            try await BatchExport.run(pages: [0, 1], destination: failed, fileExtension: "mp4") { page, output in
                if page == 1 { throw RecorderError.message("Synthetic export failure") }
                try Data("synthetic page".utf8).write(to: output)
            }
            XCTFail("Batch must fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        let cancelled = root.appendingPathComponent("cancelled")
        let (stream, signal) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { signal.finish() }
            try await BatchExport.run(pages: [0, 1], destination: cancelled, fileExtension: "m4a") { page, output in
                try Data("synthetic audio".utf8).write(to: output)
                signal.yield(page)
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        for await page in stream { XCTAssertEqual(page, 0); break }
        task.cancel()
        do { try await task.value; XCTFail("Batch must be cancelled") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertEqual(try Data(contentsOf: prior), priorBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["prior.mp4"], "Temporary batch folders must be removed")
    }
    func testBatchExportSuccessKeepsPageOrderAndRejectsExistingDestination() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("pages"), tracker = ExportPageTracker()
        try await BatchExport.run(pages: [0, 2, 10], destination: destination, fileExtension: "mp4") { page, output in
            await tracker.append(page)
            try Data("page=\(page)".utf8).write(to: output)
        }
        let order = await tracker.pages
        XCTAssertEqual(order, [0, 2, 10])
        let files = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        XCTAssertEqual(files, ["Page 001.mp4", "Page 003.mp4", "Page 011.mp4"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(files[1])), "page=2")
        do {
            try await BatchExport.run(pages: [0], destination: destination, fileExtension: "mp4") { _, _ in XCTFail("Existing destination must be rejected before exporting") }
            XCTFail("Existing destination must not be replaced")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), files)
    }
}

private actor ExportPageTracker {
    private(set) var pages: [Int] = []
    func append(_ page: Int) { pages.append(page) }
}
