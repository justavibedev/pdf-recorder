import XCTest
@testable import PDFRecorderCore

final class RehearsalTests: XCTestCase {
    func testPacingUsesTrimmedTakeAndPlaybackOffsetsButKeepsLiveTime() {
        var take = Take(duration: 60); take.trimStart = 20; take.trimEnd = 30
        XCTAssertEqual(PresentationPace.elapsed(take: take, sourceTime: 25, phase: .takeSummary), 10)
        XCTAssertEqual(PresentationPace.elapsed(take: take, sourceTime: 25, phase: .playback), 5)
        XCTAssertEqual(PresentationPace.elapsed(take: take, sourceTime: 15, phase: .playback), 0)
        XCTAssertEqual(PresentationPace.elapsed(take: take, sourceTime: 50, phase: .playback), 10)
        XCTAssertEqual(PresentationPace.elapsed(take: take, sourceTime: 25, phase: .live), 25)
        XCTAssertEqual(PresentationPace.elapsed(take: nil, sourceTime: 25, phase: .takeSummary), 0)
        XCTAssertEqual(PresentationPace.elapsed(take: nil, sourceTime: 25, phase: .live), 25)
        XCTAssertEqual(PresentationPace.elapsed(take: take, sourceTime: .nan, phase: .playback), 0)
    }
    private func fixture() -> ProjectManifest {
        var manifest = ProjectManifest(title: "Biology seminar", pageCount: 3)
        manifest.pages[0].title = "Introduction"; manifest.pages[0].targetSeconds = 60
        manifest.pages[1].title = "Cell | structure"; manifest.pages[1].targetSeconds = 75.5
        manifest.pages[2].targetSeconds = 100
        return manifest
    }
    func testRehearsalTracksVisitsAndOverrunsWithoutAudioOrEvents() {
        let start = Date(timeIntervalSince1970: 1_000)
        var session = RehearsalSession(manifest: fixture(), page: 0, now: 500, date: start)
        session.visit(page: 1, now: 560)
        session.visit(page: 0, now: 640)
        let report = session.finish(now: 655, date: start.addingTimeInterval(155))
        XCTAssertEqual(report.pages.map(\.actualSeconds), [75, 80, 0])
        XCTAssertEqual(report.pages.map(\.visits), [2, 1, 0])
        XCTAssertEqual(report.pages.map(\.overrun), [15, 4.5, 0])
        XCTAssertEqual(report.totalSeconds, 155)
        XCTAssertEqual(report.plannedSeconds, 235.5)
        XCTAssertEqual(report.totalOverrun, 19.5)
        XCTAssertEqual(report.visitedPages, 2)
        XCTAssertEqual(report.startedAt, start)
        XCTAssertEqual(session.finish(now: 900), report, "Finishing twice must not count more time")
        XCTAssertTrue(report.markdown.contains("Not visited"))
        XCTAssertTrue(report.markdown.contains("Cell \\| structure"))
        XCTAssertFalse(report.markdown.contains("notes"))
    }
    func testInvalidNavigationDoesNotResetTimerAndBackwardClockDoesNotSubtractTime() {
        var session = RehearsalSession(manifest: fixture(), page: 0, now: 100)
        session.visit(page: 0, now: 120)
        session.visit(page: -1, now: 130)
        session.visit(page: 9, now: 150)
        session.visit(page: 1, now: 160)
        session.visit(page: 0, now: 150)
        let report = session.finish(now: 170)
        XCTAssertEqual(report.pages[0].actualSeconds, 70)
        XCTAssertEqual(report.pages[1].actualSeconds, 0)
    }
    func testRehearsalHistoryRoundTripAndMissingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try RehearsalStore.load(at: root), [])
        var first = RehearsalSession(manifest: fixture(), page: 0, now: 0)
        var second = RehearsalSession(manifest: fixture(), page: 1, now: 5)
        let reports = [second.finish(now: 85.5), first.finish(now: 50)]
        try RehearsalStore.save(reports, at: root)
        XCTAssertEqual(try RehearsalStore.load(at: root), reports)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["rehearsals.json"], "Practice writes timing metadata only")
        let file = root.appendingPathComponent("rehearsals.json")
        let original = try Data(contentsOf: file)
        try Data("{\"version\":99,\"reports\":[]}".utf8).write(to: file)
        XCTAssertThrowsError(try RehearsalStore.load(at: root))
        XCTAssertThrowsError(try RehearsalStore.save(reports, at: root), "A new report must not overwrite damaged history")
        XCTAssertNotEqual(try Data(contentsOf: file), original, "Loading damaged history must not rewrite it")
    }
    func testPrompterPauseExcludesElapsedTimeAndManualScrollReanchors() {
        var clock = PrompterClock()
        XCTAssertEqual(clock.update(now: 0, running: true, speed: 20, maximum: 1_000), 0)
        XCTAssertEqual(clock.update(now: 2, running: true, speed: 20, maximum: 1_000), 40)
        XCTAssertEqual(clock.update(now: 10, running: false, speed: 20, maximum: 1_000), 40)
        XCTAssertEqual(clock.update(now: 100, running: false, speed: 20, maximum: 1_000), 40)
        XCTAssertEqual(clock.update(now: 101, running: true, speed: 20, maximum: 1_000), 60)
        clock.scroll(to: 400)
        XCTAssertEqual(clock.update(now: 200, running: true, speed: 20, maximum: 1_000), 400)
        XCTAssertEqual(clock.update(now: 300, running: true, speed: 20, maximum: 1_000), 1_000)
    }
}
