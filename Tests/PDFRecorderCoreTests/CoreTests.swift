import XCTest
import PDFKit
import AppKit
import AVFoundation
@testable import PDFRecorderCore

final class CoreTests: XCTestCase {
    func testSampleClockExcludesPausesWithoutLongRecordingDrift() {
        var clock = SampleClock(sampleRate: 48_000)
        for _ in 0..<1800 {
            clock.append(frames: 48_000, paused: false)
            clock.append(frames: 12_345, paused: true)
        }
        XCTAssertEqual(clock.duration, 1800, accuracy: 1e-9)
        clock.append(frames: 480, paused: false)
        XCTAssertEqual(clock.duration, 1800.01, accuracy: 1e-9)
    }
    func testTimelineSeekReconstructsDrawingErasingAndUndo() {
        let stroke = Stroke(tool: .pen, color: "red", width: 0.01, points: [Point(0.1, 0.2)])
        var restored = stroke; restored.points.append(Point(0.8, 0.9))
        let events: [TimedEvent] = [
            .init(time: 0, action: .beginStroke(stroke)),
            .init(time: 1, action: .extendStroke(stroke.id, Point(0.8, 0.9))),
            .init(time: 2, action: .viewport(Viewport(zoom: 2, offset: Point(0.1, -0.1)))),
            .init(time: 3, action: .removeStroke(stroke.id)),
            .init(time: 4, action: .restoreStroke(restored)),
            .init(time: 4, action: .pointer(Point(0.5, 0.5)))
        ]
        var timeline = Timeline(events: events, initialViewport: Viewport())
        XCTAssertEqual(timeline.seek(to: 1).strokes.first?.points.count, 2)
        XCTAssertTrue(timeline.seek(to: 3).strokes.isEmpty)
        XCTAssertEqual(timeline.seek(to: 4).strokes, [restored])
        XCTAssertEqual(timeline.seek(to: 0).strokes, [stroke])
        XCTAssertNil(timeline.scene.pointer)
        XCTAssertEqual(timeline.scene.viewport.zoom, 1)
    }
    func testPageCoordinatesRoundTripAcrossAspectRatiosAndViewports() {
        for page in [CGSize(width: 612, height: 792), CGSize(width: 1920, height: 1080), CGSize(width: 900, height: 400)] {
            for zoom in [1.0, 2.5, 8] {
                let geometry = PageGeometry(canvas: CGRect(x: 20, y: 10, width: 960, height: 540), pageSize: page,
                                            viewport: Viewport(zoom: zoom, offset: Point(0.2, -0.3)))
                for point in [Point(0, 0), Point(0.5, 0.5), Point(1, 1)] {
                    let result = geometry.toPage(geometry.toCanvas(point))
                    XCTAssertEqual(point.x, result.x, accuracy: 1e-10)
                    XCTAssertEqual(point.y, result.y, accuracy: 1e-10)
                }
            }
        }
    }
    func testIndependentRetakesSelectionAndDeletion() {
        var manifest = ProjectManifest(title: "Example", pageCount: 3)
        let takes = (0..<3).map { _ in Take(duration: 2) }
        for index in 0..<3 { manifest.pages[index].add(takes[index]) }
        let retake = Take(duration: 5)
        manifest.pages[1].add(retake)
        XCTAssertEqual(manifest.selectedTakes.map(\.take.id), [takes[0].id, retake.id, takes[2].id])
        manifest.pages[1].selectedTakeID = takes[1].id
        XCTAssertEqual(manifest.selectedTakes.map(\.take.id), takes.map(\.id))
        manifest.pages[1].delete(takes[1].id)
        XCTAssertEqual(manifest.pages[1].selectedTakeID, retake.id)
        XCTAssertEqual(manifest.pages[0].takes, [takes[0]])
    }
    func testPortableProjectRoundTripAndRecoverPartialTake() throws {
        let workspace = try scratch(); defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("original.pdf")
        try fixturePDF().dataRepresentation()!.write(to: source)
        let original = try Data(contentsOf: source)
        let root = workspace.appendingPathComponent("test.pdfrecorder")
        let manifest = try ProjectStore.create(at: root, source: source, title: "Study", pageCount: 3)
        let take = Take(duration: 1)
        let audio = try ProjectStore.prepare(take, at: root)
        try writeAudio(at: audio, duration: 1)
        let events = [TimedEvent(time: 0.2, action: .pointer(Point(0.3, 0.7)))]
        try ProjectStore.journal(ActiveTake(page: 1, take: take, events: events), at: root)
        let recovered = try ProjectStore.recover(at: root, manifest: manifest)
        XCTAssertTrue(recovered.pages[1].selectedTake!.recovered)
        XCTAssertEqual(recovered.pages[1].selectedTake!.duration, 1, accuracy: 0.001)
        let moved = workspace.appendingPathComponent("moved.pdfrecorder")
        try FileManager.default.moveItem(at: root, to: moved)
        let loaded = try ProjectStore.load(at: moved)
        XCTAssertEqual(loaded, recovered)
        XCTAssertEqual(try ProjectStore.events(for: loaded.pages[1].selectedTake!, at: moved), events)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testRejectsUnsafePathsInvalidTimelinesAndMissingFiles() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProjectStore.location("../secret", in: root))
        XCTAssertThrowsError(try ProjectStore.location("/etc/passwd", in: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ProjectStore.location("escape/file", in: root))
        XCTAssertThrowsError(try ProjectStore.validate([.init(time: -1, action: .pointer(nil))]))
        XCTAssertThrowsError(try ProjectStore.validate([.init(time: 1, action: .viewport(Viewport(zoom: 0)))]))
        var manifest = ProjectManifest(title: "Missing", pageCount: 1)
        manifest.pages[0].add(Take(duration: 2))
        try ProjectStore.save(manifest, at: root)
        XCTAssertThrowsError(try ProjectStore.load(at: root))
        manifest.version = 42
        try ProjectStore.save(manifest, at: root)
        XCTAssertThrowsError(try ProjectStore.load(at: root))
    }
    func testRotatedAndMixedPDFArtworkGeometry() throws {
        let pdf = fixturePDF()
        for (index, expected) in [CGSize(width: 612, height: 792), CGSize(width: 960, height: 540), CGSize(width: 792, height: 612)].enumerated() {
            let artwork = try PageArtwork(page: pdf.page(at: index)!, maximumDimension: 960)
            XCTAssertEqual(artwork.size, expected)
            XCTAssertEqual(Double(artwork.image.width) / Double(artwork.image.height), expected.width / expected.height, accuracy: 0.01)
            XCTAssertNotNil(SceneRenderer.image(artwork: artwork, scene: Scene(), size: CGSize(width: 960, height: 540)))
        }
    }
    func testExportCreatesPlayableMP4WithAudioAndCorrectDuration() async throws {
        let workspace = try scratch(); defer { try? FileManager.default.removeItem(at: workspace) }
        let pdf = workspace.appendingPathComponent("source.pdf")
        try fixturePDF().dataRepresentation()!.write(to: pdf)
        var items: [ExportItem] = []
        for page in 0..<3 {
            let take = Take(duration: 0.3)
            let audio = workspace.appendingPathComponent("\(page).caf")
            try writeAudio(at: audio, duration: 0.3)
            items.append(ExportItem(page: page, take: take, events: [.init(time: 0, action: .pointer(Point(0.3, 0.7)))], audioURL: audio))
        }
        let output = workspace.appendingPathComponent("result.mp4")
        try await VideoExporter.export(pdfURL: pdf, password: nil, items: items, to: output, progress: { _ in })
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration.seconds, 0.9, accuracy: 0.05)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        let result = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        XCTAssertEqual(result.image.width, 1920)
        XCTAssertEqual(result.image.height, 1080)
        let rate = try await video[0].load(.nominalFrameRate)
        XCTAssertEqual(rate, 30, accuracy: 0.1)
        let descriptions = try await audio[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(descriptions[0]), kAudioFormatMPEG4AAC)
        // Compare an exported frame to the same scene rendered directly; catches flipped buffers and missing pointer layers.
        let referencePDF = fixturePDF()
        let artwork = try PageArtwork(page: referencePDF.page(at: 0)!)
        var scene = Scene(); scene.pointer = Point(0.3, 0.7)
        let expected = SceneRenderer.image(artwork: artwork, scene: scene, size: CGSize(width: 1920, height: 1080))!
        let actualPixels = pixels(result.image)
        let expectedPixels = pixels(expected)
        let meanError = zip(actualPixels, expectedPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(actualPixels.count)
        XCTAssertLessThan(meanError, 8, "Export differs from the shared renderer")
        func blueMask(_ values: [UInt8]) -> Set<Int> {
            Set(stride(from: 0, to: values.count, by: 4).filter { values[$0] < 90 && values[$0 + 2] > 180 })
        }
        let expectedBlue = blueMask(expectedPixels), actualBlue = blueMask(actualPixels)
        XCTAssertGreaterThan(expectedBlue.count, 50)
        XCTAssertGreaterThan(Double(expectedBlue.intersection(actualBlue).count) / Double(expectedBlue.union(actualBlue).count), 0.85,
                             "Exported content is shifted or flipped")
        if let artifactPath = ProcessInfo.processInfo.environment["PDFRECORDER_TEST_ARTIFACTS"] {
            let artifacts = URL(fileURLWithPath: artifactPath)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            try Data(contentsOf: output).write(to: artifacts.appendingPathComponent("export-smoke.mp4"))
            try Data(contentsOf: pdf).write(to: artifacts.appendingPathComponent("geometry-fixture.pdf"))
            try NSBitmapImageRep(cgImage: result.image).representation(using: .png, properties: [:])!.write(to: artifacts.appendingPathComponent("export-frame.png"))
        }
    }
    func testCancelledExportPreservesExistingDestination() async throws {
        let workspace = try scratch(); defer { try? FileManager.default.removeItem(at: workspace) }
        let pdf = workspace.appendingPathComponent("source.pdf")
        try fixturePDF().dataRepresentation()!.write(to: pdf)
        let audio = workspace.appendingPathComponent("audio.caf"); try writeAudio(at: audio, duration: 1)
        let output = workspace.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing video".utf8); try sentinel.write(to: output)
        let task = Task {
            try Task.checkCancellation()
            try await VideoExporter.export(pdfURL: pdf, password: nil, items: [.init(page: 0, take: Take(duration: 1), events: [], audioURL: audio)], to: output, progress: { _ in })
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }
    func testJournalAppendsAndIgnoresOnlyTruncatedLastLine() throws {
        let workspace = try scratch(); defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("original.pdf")
        try fixturePDF().dataRepresentation()!.write(to: source)
        let root = workspace.appendingPathComponent("test.pdfrecorder")
        let manifest = try ProjectStore.create(at: root, source: source, title: "Journal", pageCount: 3)
        let take = Take(duration: 1)
        try writeAudio(at: ProjectStore.prepare(take, at: root), duration: 1)
        let first = TimedEvent(time: 0.1, action: .pointer(Point(0.1, 0.2)))
        let second = TimedEvent(time: 0.2, action: .pointer(nil))
        let index = try ProjectStore.journal(ActiveTake(page: 0, take: take, events: [first]), at: root)
        try ProjectStore.journal(ActiveTake(page: 0, take: take, events: [first, second]), from: index, at: root)
        let log = try ProjectStore.location(take.eventsPath, in: root).deletingPathExtension().appendingPathExtension("ndjson")
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: Data("{truncated".utf8)); try handle.close()
        let recovered = try ProjectStore.recover(at: root, manifest: manifest)
        XCTAssertEqual(try ProjectStore.events(for: recovered.pages[0].selectedTake!, at: root), [first, second])
    }
    func testScannedPDFAndEmbeddedAnnotationsAppearInRenderer() throws {
        let bitmap = NSImage(size: CGSize(width: 400, height: 600), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSColor.black.setFill(); NSRect(x: 50, y: 300, width: 280, height: 20).fill()
            return true
        }
        let page = PDFPage(image: bitmap)!
        let document = PDFDocument(); document.insert(page, at: 0)
        let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 100, width: 200, height: 80), forType: .square, withProperties: nil)
        annotation.interiorColor = .red; annotation.color = .red; page.addAnnotation(annotation)
        let artwork = try PageArtwork(page: page, maximumDimension: 600)
        let output = SceneRenderer.image(artwork: artwork, scene: Scene(), size: CGSize(width: 960, height: 540))!
        let values = pixels(output)
        var redPixels = 0
        for i in stride(from: 0, to: values.count, by: 4) {
            if values[i] > 180 && values[i + 1] < 80 && values[i + 2] < 80 { redPixels += 1 }
        }
        // The annotation occupies roughly 500 pixels in the 192x108 analysis image.
        XCTAssertGreaterThan(redPixels, 400)
        withExtendedLifetime(document) {}
    }
    func testCancellationAfterRenderingBeginsKeepsExistingFile() async throws {
        let workspace = try scratch(); defer { try? FileManager.default.removeItem(at: workspace) }
        let pdf = workspace.appendingPathComponent("source.pdf")
        try fixturePDF().dataRepresentation()!.write(to: pdf)
        let audio = workspace.appendingPathComponent("audio.caf"); try writeAudio(at: audio, duration: 1)
        let destination = workspace.appendingPathComponent("keep.mp4")
        let original = Data("existing file must survive".utf8); try original.write(to: destination)
        let (signal, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { continuation.finish() }
            try await VideoExporter.export(pdfURL: pdf, password: nil,
                                           items: [.init(page: 0, take: Take(duration: 60), events: [], audioURL: audio)],
                                           to: destination, width: 640, height: 360) { progress in
                if progress > 0 { continuation.yield(()) }
            }
        }
        for await _ in signal { break }
        task.cancel()
        do { try await task.value; XCTFail("Expected in-progress cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: workspace.path).contains { $0.hasPrefix(".pdfrecorder-") })
    }
}

func pixels(_ image: CGImage) -> [UInt8] {
    let width = 192, height = 108
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
}

func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-recorder-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func writeAudio(at url: URL, duration: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48_000))!
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.05 }
    try file.write(from: buffer)
}

func fixturePDF() -> PDFDocument {
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data)!
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for (index, size) in [CGSize(width: 612, height: 792), CGSize(width: 960, height: 540), CGSize(width: 612, height: 792)].enumerated() {
        var rect = CGRect(origin: .zero, size: size)
        let media = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: media] as CFDictionary)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.setFillColor(CGColor(red: 0.1, green: 0.35 + Double(index) * 0.15, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 100, height: 100))
        context.endPDFPage()
    }
    context.closePDF()
    let pdf = PDFDocument(data: data as Data)!
    pdf.page(at: 2)!.rotation = 90
    return pdf
}
