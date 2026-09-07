import Foundation
@preconcurrency import AVFoundation
import PDFKit
import AppKit

public struct ExportItem {
    public var page: Int
    public var take: Take
    public var events: [TimedEvent]
    public var audioURL: URL
    public init(page: Int, take: Take, events: [TimedEvent], audioURL: URL) {
        self.page = page; self.take = take; self.events = events; self.audioURL = audioURL
    }
}

public enum VideoExporter {
    /// Work is isolated on the caller's background task. At most one page bitmap and one video frame are retained.
    public static func export(pdfURL: URL, password: String?, items: [ExportItem], to destination: URL,
                              width: Int = 1920, height: Int = 1080,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !items.isEmpty else { throw RecorderError.message("Record at least one page before exporting.") }
        guard let pdf = PDFDocument(url: pdfURL) else { throw RecorderError.message("The source PDF could not be opened.") }
        if pdf.isLocked { guard pdf.unlock(withPassword: password ?? "") else { throw RecorderError.message("Unlock the PDF before exporting.") } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let silentURL = temporary.appendingPathComponent("frames.mov")
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoMaxKeyFrameIntervalKey: 60]
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
        let totalFrames = items.reduce(0) { $0 + Int(ceil($1.take.duration * 30)) }
        var frameIndex = 0
        var segments: [(ExportItem, CMTime, CMTime)] = []
        do {
            for item in items {
                try Task.checkCancellation()
                guard let page = pdf.page(at: item.page) else { throw RecorderError.message("A recorded PDF page is missing.") }
                let artwork = try PageArtwork(page: page)
                var timeline = Timeline(events: item.events, initialViewport: item.take.initialViewport)
                let count = Int(ceil(item.take.duration * 30))
                segments.append((item, CMTime(value: Int64(frameIndex), timescale: 30), CMTime(value: Int64(count), timescale: 30)))
                for localFrame in 0..<count {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed { throw writer.error ?? RecorderError.message("Video encoding failed.") }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    let scene = timeline.seek(to: Double(localFrame) / 30)
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
        let videoAsset = AVURLAsset(url: silentURL)
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sourceTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("Could not assemble the presentation.")
        }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: Int64(frameIndex), timescale: 30)), of: sourceTrack, at: .zero)
        for (item, start, duration) in segments {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: item.audioURL)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RecorderError.message("A take's audio is missing.") }
            let available = try await asset.load(.duration)
            let length = CMTimeMinimum(duration, available)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: start)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw RecorderError.message("MP4 export is unavailable on this Mac.")
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".pdfrecorder-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        session.outputURL = staged; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        let reporter = Task {
            while !Task.isCancelled {
                progress(0.8 + Double(session.progress) * 0.2)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { reporter.cancel() }
        await withTaskCancellationHandler(operation: { await session.export() }, onCancel: { session.cancelExport() })
        try Task.checkCancellation()
        guard session.status == .completed else { throw RecorderError.message("Assembling MP4 failed: \(session.error?.localizedDescription ?? "Unknown export error")") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        progress(1)
    }
}
