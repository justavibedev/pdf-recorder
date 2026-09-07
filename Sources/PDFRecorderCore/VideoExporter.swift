import Foundation
@preconcurrency import AVFoundation
import PDFKit
import AppKit

public struct ExportItem: Sendable {
    public var page: Int
    public var take: Take
    public var events: [TimedEvent]
    public var audioURL: URL
    public var eventsURL: URL?
    public init(page: Int, take: Take, events: [TimedEvent], audioURL: URL) {
        self.page = page; self.take = take; self.events = events; self.audioURL = audioURL
    }
    public init(page: Int, take: Take, eventsURL: URL, audioURL: URL) {
        self.page = page; self.take = take; self.events = []; self.eventsURL = eventsURL; self.audioURL = audioURL
    }
    public func loadEvents() throws -> [TimedEvent] {
        if let eventsURL { return try EventLogReader.readAll(url: eventsURL) }
        return events
    }
}

public enum VideoExporter {
    // AVFoundation explicitly supports cancelling an export from another thread.
    private struct CancellationHandle: @unchecked Sendable {
        let session: AVAssetExportSession
        func cancel() { session.cancelExport() }
    }
    /// Work is isolated on the caller's background task. At most one page bitmap and one video frame are retained.
    public static func export(pdfURL: URL, password: String?, items: [ExportItem], to destination: URL,
                              width: Int? = nil, height: Int? = nil, options: ExportOptions = ExportOptions(),
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !items.isEmpty, items.allSatisfy({ $0.take.playbackDuration > 0 }) else { throw RecorderError.message("Select at least one take with a nonempty trim range before exporting.") }
        let width = width ?? options.preset.width, height = height ?? options.preset.height
        guard width > 0, height > 0, items.allSatisfy({ $0.take.duration.isFinite && $0.take.playbackDuration * 30 < Double(Int.max) }) else {
            throw RecorderError.message("The export dimensions or a take's duration are invalid.")
        }
        guard let pdf = PDFDocument(url: pdfURL) else { throw RecorderError.message("The source PDF could not be opened.") }
        if pdf.isLocked { guard pdf.unlock(withPassword: password ?? "") else { throw RecorderError.message("Unlock the PDF before exporting.") } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let silentURL = temporary.appendingPathComponent("frames.mov")
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: options.preset.videoBitRate, AVVideoMaxKeyFrameIntervalKey: 60]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw RecorderError.message("The video encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.message("Could not start video export.") }
        writer.startSession(atSourceTime: .zero)
        let totalFrames = items.reduce(0) { $0 + Int(ceil($1.take.playbackDuration * 30)) }
        var frameIndex = 0
        var segments: [(ExportItem, CMTime, CMTime)] = []
        do {
            for item in items {
                try Task.checkCancellation()
                guard let page = pdf.page(at: item.page) else { throw RecorderError.message("A recorded PDF page is missing.") }
                let artwork = try PageArtwork(page: page)
                let timeline = try ExportTimeline(item: item)
                let count = Int(ceil(item.take.playbackDuration * 30))
                segments.append((item, CMTime(value: Int64(frameIndex), timescale: 30), CMTime(value: Int64(count), timescale: 30)))
                for localFrame in 0..<count {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed { throw writer.error ?? RecorderError.message("Video encoding failed.") }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    let scene = try timeline.seek(to: item.take.playbackStart + Double(localFrame) / 30)
                    try autoreleasepool {
                        var buffer: CVPixelBuffer?
                        guard let pool = adaptor.pixelBufferPool,
                              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                              let buffer else { throw RecorderError.message("Could not allocate an export frame.") }
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                            throw RecorderError.message("Could not render an export frame.")
                        }
                        SceneRenderer.draw(artwork: artwork, scene: scene, in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))
                        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 30)) else {
                            throw writer.error ?? RecorderError.message("Could not write an export frame.")
                        }
                    }
                    frameIndex += 1
                    if frameIndex % 15 == 0 { progress(Double(frameIndex) / Double(totalFrames) * 0.8) }
                }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(frameIndex), timescale: 30))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? RecorderError.message("Video encoding failed.") }
        } catch is CancellationError { writer.cancelWriting(); throw CancellationError() }
        catch { writer.cancelWriting(); throw RecorderError.message("Rendering video failed: \(error.localizedDescription)") }
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silentURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioComposition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = audioComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sourceTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("Could not assemble the presentation.")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: Int64(frameIndex), timescale: 30)), of: sourceTrack, at: .zero)
        for (item, start, duration) in segments {
            try Task.checkCancellation()
            let processed = temporary.appendingPathComponent("\(UUID().uuidString).caf")
            try await AudioProcessing.renderPlayback(take: item.take, source: item.audioURL, to: processed,
                                                     matchLoudness: options.matchLoudness, fadeSeconds: options.boundaryFadeSeconds)
            let asset = AVURLAsset(url: processed, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RecorderError.message("A take's audio is missing.") }
            let available = try await asset.load(.duration)
            let length = CMTimeMinimum(duration, available)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: start)
        }
        // Encode audio separately, then mux with passthrough so the chosen H.264 bitrate and dimensions survive.
        let encodedAudioURL = temporary.appendingPathComponent("audio.m4a")
        guard let audioSession = AVAssetExportSession(asset: audioComposition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.message("AAC audio export is unavailable on this Mac.")
        }
        audioSession.outputURL = encodedAudioURL; audioSession.outputFileType = .m4a
        audioSession.timeRange = CMTimeRange(start: .zero, duration: audioComposition.duration)
        try await run(audioSession) { progress(0.8 + $0 * 0.1) }
        let encodedAudio = AVURLAsset(url: encodedAudioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let encodedTrack = try await encodedAudio.loadTracks(withMediaType: .audio).first,
              let finalAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError.message("The encoded presentation audio could not be read.")
        }
        let audioDuration = CMTimeMinimum(try await encodedAudio.load(.duration), CMTime(value: Int64(frameIndex), timescale: 30))
        try finalAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: encodedTrack, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RecorderError.message("MP4 export is unavailable on this Mac.")
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".pdfrecorder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        session.outputURL = staged; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        try await run(session) { progress(0.9 + $0 * 0.1) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        progress(1)
    }
    private static func run(_ session: AVAssetExportSession, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let reporter = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { reporter.cancel() }
        let cancellation = CancellationHandle(session: session)
        await withTaskCancellationHandler(operation: { await session.export() }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        guard session.status == .completed else { throw RecorderError.message("Assembling MP4 failed: \(session.error?.localizedDescription ?? "Unknown export error")") }
    }
}
