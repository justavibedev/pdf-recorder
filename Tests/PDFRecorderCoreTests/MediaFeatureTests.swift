import XCTest
import AVFoundation
import PDFKit
@testable import PDFRecorderCore

final class MediaFeatureTests: XCTestCase {
    func testTakeMetadataRoundTripAndLegacyDefaults() throws {
        let original = Take(duration: 10)
        let legacy = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Take.self, from: legacy)
        XCTAssertEqual(decoded.playbackStart, 0)
        XCTAssertEqual(decoded.playbackEnd, 10)
        XCTAssertNil(decoded.name)
        var edited = decoded
        edited.trimStart = 2; edited.trimEnd = 8; edited.name = "  Worked example  "
        edited.favorite = true; edited.reviewStatus = .needsCorrection
        edited.reviewMarkers = [.init(time: 4, label: "Check equation")]
        edited.loopRange = .init(start: 3, end: 5); edited.gainDB = 3
        XCTAssertEqual(edited.playbackDuration, 6)
        XCTAssertEqual(edited.displayName, "Worked example")
        XCTAssertEqual(edited.audioPath, original.audioPath)
        XCTAssertEqual(edited.duration, 10, "Trimming must preserve the original duration")
        XCTAssertEqual(try JSONDecoder().decode(Take.self, from: JSONEncoder().encode(edited)), edited)
    }

    func testCheckpointedLongTimelineMatchesFreshReconstruction() {
        let stroke = Stroke(tool: .pen, color: "blue", width: 0.01, points: [Point(0, 0)])
        var events = [TimedEvent(time: 0, action: .beginStroke(stroke))]
        for i in 1...25_000 {
            let action: SceneAction = i % 100 == 0 ? .extendStroke(stroke.id, Point(Double(i) / 25_000, 0.5)) : .pointer(Point(Double(i) / 25_000, 0.3))
            events.append(.init(time: Double(i) / 30, action: action))
        }
        var timeline = Timeline(events: events, initialViewport: Viewport())
        _ = timeline.seek(to: 1000)
        XCTAssertGreaterThan(timeline.checkpointCount, 20)
        XCTAssertLessThanOrEqual(timeline.checkpointCount, 48)
        for time in [0.0, 1, 500, 33, 800, 400, 700, 200] {
            var expected = Scene()
            for event in events where event.time <= time { expected.apply(event.action) }
            XCTAssertEqual(timeline.seek(to: time), expected)
        }
    }

    func testStreamingEventReaderHandlesLargeLogsEscapesAndMalformedInput() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.json")
        let stroke = Stroke(tool: .text, color: "blue", width: 0.04, points: [Point(0.2, 0.2)], text: "Quoted \" ] } \\ café")
        let events = [.init(time: 0, action: SceneAction.beginStroke(stroke))] + (1...6000).map { TimedEvent(time: Double($0), action: .pointer(Point(0.2, 0.4))) }
        let data = try JSONEncoder().encode(events)
        XCTAssertGreaterThan(data.count, 65_536)
        try data.write(to: url)
        XCTAssertEqual(try EventLogReader.readAll(url: url), events)
        for invalid in ["[", "{}", "[{}]", "[] trailing", "[\(String(data: try JSONEncoder().encode(events[0]), encoding: .utf8)!),]"] {
            try Data(invalid.utf8).write(to: url)
            XCTAssertThrowsError(try EventLogReader.readAll(url: url))
        }
        try JSONEncoder().encode([events[2], events[1]]).write(to: url)
        XCTAssertThrowsError(try EventLogReader.readAll(url: url))
    }

    func testWaveformDistinguishesSilenceSpeechAndClipping() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("wave.caf")
        try signal(url: url, duration: 1) { frame in
            switch frame / 12_000 {
            case 0: return 0
            case 1: return Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.05
            case 2: return Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.8
            default: return 1
            }
        }
        let analysis = try AudioAnalysis.analyze(url: url, binCount: 4)
        XCTAssertEqual(analysis.duration, 1, accuracy: 0.0001)
        XCTAssertEqual(analysis.bins.count, 4)
        XCTAssertEqual(analysis.bins[0].rms, 0)
        XCTAssertEqual(analysis.bins[1].peak, 0.05, accuracy: 0.001)
        XCTAssertFalse(analysis.bins[2].clipped)
        XCTAssertTrue(analysis.bins[3].clipped)
        XCTAssertTrue(analysis.clipped)
        let silence = try AudioAnalysis.analyze(url: url, trim: .init(start: 0, end: 0.25))
        XCTAssertTrue(silence.isSilent)
    }

    func testTrimGainAndFadeProcessingPreservesSourceAndMatchesLengths() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("original.caf"), output = root.appendingPathComponent("playback.caf")
        try signal(url: input, duration: 1) { frame in Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.1 }
        let original = try Data(contentsOf: input)
        var take = Take(duration: 1); take.trimStart = 0.2; take.trimEnd = 0.7; take.gainDB = -6
        try await AudioProcessing.renderPlayback(take: take, source: input, to: output, matchLoudness: false)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.5, accuracy: 0.0001)
        let result = try AudioAnalysis.analyze(url: output, binCount: 50)
        XCTAssertEqual(result.peak, 0.1 * Float(pow(10, -6.0 / 20)), accuracy: 0.001)
        XCTAssertLessThan(result.bins.first!.rms, result.bins[10].rms)
        XCTAssertLessThan(result.bins.last!.rms, result.bins[10].rms)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testLoudnessMatchingProducesSimilarSpeechLevels() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var levels: [Double] = []
        for (index, amplitude) in [Float(0.08), 0.4].enumerated() {
            let input = root.appendingPathComponent("\(index).caf"), output = root.appendingPathComponent("matched\(index).caf")
            try signal(url: input, duration: 0.4) { frame in Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * amplitude }
            try await AudioProcessing.renderPlayback(take: Take(duration: 0.4), source: input, to: output, matchLoudness: true)
            let result = try AudioAnalysis.analyze(url: output)
            levels.append(result.rmsDB)
            XCTAssertFalse(result.clipped)
        }
        XCTAssertEqual(levels[0], levels[1], accuracy: 0.1)
        XCTAssertEqual(levels[0], -20, accuracy: 0.3)
    }

    func testTrimmedVideoPreservesSceneAtTrimStartAndSmallPreset() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("source.pdf"), audioURL = root.appendingPathComponent("take.caf")
        let pdf = fixturePDF(); try pdf.dataRepresentation()!.write(to: pdfURL)
        try writeAudio(at: audioURL, duration: 0.8)
        var take = Take(duration: 0.8); take.trimStart = 0.4; take.trimEnd = 0.7
        let events: [TimedEvent] = [.init(time: 0.1, action: .viewport(Viewport(zoom: 1.5, offset: Point(0.1, 0)))),
                                     .init(time: 0.2, action: .pointer(Point(0.3, 0.7)))]
        let log = root.appendingPathComponent("events.json"); try JSONEncoder().encode(events).write(to: log)
        let output = root.appendingPathComponent("trimmed.mp4")
        try await VideoExporter.export(pdfURL: pdfURL, password: nil,
                                       items: [.init(page: 0, take: take, eventsURL: log, audioURL: audioURL)], to: output,
                                       options: ExportOptions(preset: .small)) { _ in }
        let asset = AVURLAsset(url: output)
        let length = try await asset.load(.duration)
        XCTAssertEqual(length.seconds, 0.3, accuracy: 0.04)
        let result = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        XCTAssertEqual(result.image.width, 1280); XCTAssertEqual(result.image.height, 720)
        var timeline = Timeline(events: events, initialViewport: take.initialViewport)
        let artwork = try PageArtwork(page: pdf.page(at: 0)!)
        let expected = SceneRenderer.image(artwork: artwork, scene: timeline.seek(to: 0.5), size: CGSize(width: 1280, height: 720))!
        let error = zip(pixels(expected), pixels(result.image)).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels(expected).count)
        XCTAssertLessThan(error, 8)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await audio[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(descriptions[0]), kAudioFormatMPEG4AAC)
    }

    func testAudioExportHonorsTrimAndCancellationPreservesSource() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.caf"), output = root.appendingPathComponent("trimmed.m4a")
        try writeAudio(at: input, duration: 0.8)
        var take = Take(duration: 0.8); take.trimStart = 0.2; take.trimEnd = 0.5
        try await AudioExporter.export(items: [.init(page: 0, take: take, events: [], audioURL: input)], to: output) { _ in }
        let duration = try await AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]).load(.duration)
        XCTAssertEqual(duration.seconds, 0.3, accuracy: 0.03)
        // Check the decoded PCM rather than relying only on container duration estimates:
        // AAC priming/remainder packets must not remove any part of the 0.3-second trim.
        let decoded = try AVAudioFile(forReading: output)
        let expectedFrames = Int64((take.playbackDuration * decoded.processingFormat.sampleRate).rounded())
        XCTAssertEqual(decoded.length, expectedFrames)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 8192)!
        var decodedFrames: Int64 = 0
        while decoded.framePosition < decoded.length {
            try decoded.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            decodedFrames += Int64(buffer.frameLength)
        }
        XCTAssertEqual(decodedFrames, expectedFrames)
        let original = try Data(contentsOf: output)
        let task = Task { [take] in try await AudioExporter.export(items: [.init(page: 0, take: take, events: [], audioURL: input)], to: output) { _ in } }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testExportEstimatesReflectQualityAndProgress() {
        let small = ExportOptions(preset: .small), high = ExportOptions(preset: .high)
        XCTAssertGreaterThan(high.estimatedBytes(duration: 600), small.estimatedBytes(duration: 600) * 4)
        XCTAssertEqual(small.estimatedBytes(duration: 0), 0)
        XCTAssertEqual(small.estimatedBytes(duration: Double.greatestFiniteMagnitude), Int64.max)
        XCTAssertEqual(small.estimatedBytes(duration: 600, audioOnly: true), high.estimatedBytes(duration: 600, audioOnly: true))
        XCTAssertNil(ExportOptions.estimatedSecondsRemaining(progress: 0, elapsed: 10))
        XCTAssertEqual(ExportOptions.estimatedSecondsRemaining(progress: 0.25, elapsed: 10), 30)
    }

    func testPlaybackProcessingRejectsSourceOverwriteAndInvalidRange() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.caf")
        try writeAudio(at: input, duration: 0.1)
        let original = try Data(contentsOf: input)
        do {
            try await AudioProcessing.renderPlayback(take: Take(duration: 0.1), source: input, to: input, matchLoudness: false)
            XCTFail("Source overwrite must be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertThrowsError(try AudioAnalysis.analyze(url: input, trim: .init(start: .infinity, end: 1)))
        XCTAssertThrowsError(try AudioAnalysis.analyze(url: input, trim: .init(start: 0.1, end: 0)))
    }

    private func signal(url: URL, duration: Double, value: (Int) -> Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48_000))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = value(frame) }
        try file.write(from: buffer)
    }
}
