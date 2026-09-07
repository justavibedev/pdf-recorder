import XCTest
import AVFoundation
@testable import PDFRecorderCore

final class PlaybackAudioCacheTests: XCTestCase {
    func testReusesUnchangedAudioAndInvalidatesProcessingEdits() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        try writeAudio(at: source, duration: 0.3)
        let original = try Data(contentsOf: source)
        let cache = PlaybackAudioCache(directory: root.appendingPathComponent("cache"))
        var take = Take(duration: 0.3)
        let first = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        let creation = try first.resourceValues(forKeys: [.creationDateKey]).creationDate
        take.name = "Renaming does not change audio"
        let reused = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        XCTAssertEqual(reused, first)
        XCTAssertEqual(try reused.resourceValues(forKeys: [.creationDateKey]).creationDate, creation)
        take.trimStart = 0.1
        let trimmed = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        XCTAssertNotEqual(trimmed, first)
        let file = try AVAudioFile(forReading: trimmed)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.2, accuracy: 0.001)
        take.gainDB = -3
        let quieter = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        let matched = try await cache.preparedURL(take: take, source: source, matchLoudness: true)
        XCTAssertNotEqual(quieter, trimmed); XCTAssertNotEqual(matched, quieter)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testLeastRecentlyUsedEntryIsEvictedAndCacheSurvivesRecreation() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf"), directory = root.appendingPathComponent("cache")
        try writeAudio(at: source, duration: 0.1)
        let cache = PlaybackAudioCache(directory: directory)
        var urls: [URL] = []
        for gain in [0.0, -1, -2] {
            var take = Take(duration: 0.1); take.gainDB = gain
            urls.append(try await cache.preparedURL(take: take, source: source, matchLoudness: false))
        }
        _ = try await cache.preparedURL(take: Take(duration: 0.1), source: source, matchLoudness: false)
        var fourth = Take(duration: 0.1); fourth.gainDB = -3
        let newest = try await cache.preparedURL(take: fourth, source: source, matchLoudness: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[2].path))
        XCTAssertEqual(try completed(in: directory).count, 3)
        let recreated = PlaybackAudioCache(directory: directory)
        let reused = try await recreated.preparedURL(take: fourth, source: source, matchLoudness: false)
        XCTAssertEqual(reused, newest)
    }

    func testByteBudgetRetainsOnlyOneOversizedCurrentClip() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf"), directory = root.appendingPathComponent("cache")
        try writeAudio(at: source, duration: 0.1)
        let cache = PlaybackAudioCache(directory: directory, maxBytes: 1)
        let old = try await cache.preparedURL(take: Take(duration: 0.1), source: source, matchLoudness: false)
        var take = Take(duration: 0.1); take.gainDB = -3
        let current = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(try completed(in: directory).count, 1)
    }

    func testSourceModificationInvalidatesCachedAudio() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        try writeAudio(at: source, duration: 0.1)
        let cache = PlaybackAudioCache(directory: root.appendingPathComponent("cache"))
        let take = Take(duration: 0.1)
        let first = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: source.path)
        let replaced = try await cache.preparedURL(take: take, source: source, matchLoudness: false)
        XCTAssertNotEqual(first, replaced)
    }

    func testCancelledAndOverlappingPreparationLeaveOnlyCompleteClips() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf"), directory = root.appendingPathComponent("cache")
        try writeAudio(at: source, duration: 0.2)
        let original = try Data(contentsOf: source)
        let cache = PlaybackAudioCache(directory: directory)
        let cancelled = Task { try await cache.preparedURL(take: Take(duration: 0.2), source: source, matchLoudness: false) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        async let first = cache.preparedURL(take: Take(duration: 0.2), source: source, matchLoudness: false)
        async let second = cache.preparedURL(take: Take(duration: 0.2), source: source, matchLoudness: false)
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        XCTAssertEqual(try completed(in: directory).count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertGreaterThan(try AVAudioFile(forReading: one).length, 0)
    }

    func testInFlightCancellationCleansPartialAudioAndKeepsPreviousClip() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf"), directory = root.appendingPathComponent("cache")
        try writeAudio(at: source, duration: 30)
        let cache = PlaybackAudioCache(directory: directory)
        let previous = try await cache.preparedURL(take: Take(duration: 0.1), source: source, matchLoudness: false)
        let job = Task { try await cache.preparedURL(take: Take(duration: 30), source: source, matchLoudness: true) }
        var sawPending = false
        for _ in 0..<500 {
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") }) == true { sawPending = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawPending, "The cancellation should exercise an active write, not just an unstarted task")
        job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancellation during preparation") } catch is CancellationError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testCleanupPreservesUnrelatedFilesAndCacheCanBeReused() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf"), directory = root.appendingPathComponent("cache")
        try writeAudio(at: source, duration: 0.1)
        let cache = PlaybackAudioCache(directory: directory)
        let first = try await cache.preparedURL(take: Take(duration: 0.1), source: source, matchLoudness: false)
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let similarlyNamed = directory.appendingPathComponent("clip-unrelated.caf")
        try Data("also keep".utf8).write(to: similarlyNamed)
        try await cache.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
        XCTAssertEqual(try String(contentsOf: similarlyNamed), "also keep")
        let next = try await cache.preparedURL(take: Take(duration: 0.1), source: source, matchLoudness: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCleanupCancelsActivePreparationBeforeRemovingDirectory() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf"), directory = root.appendingPathComponent("cache")
        try writeAudio(at: source, duration: 30)
        let cache = PlaybackAudioCache(directory: directory)
        let job = Task { try await cache.preparedURL(take: Take(duration: 30), source: source, matchLoudness: true) }
        var sawPending = false
        for _ in 0..<500 {
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pending-") }) == true { sawPending = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawPending)
        try await cache.removeAll()
        do { _ = try await job.value; XCTFail("Cleanup should cancel active preparation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func completed(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("clip-") }
    }
}
