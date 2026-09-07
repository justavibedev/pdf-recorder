import Foundation
@preconcurrency import AVFoundation

public enum AudioExporter {
    private struct CancellationHandle: @unchecked Sendable {
        let session: AVAssetExportSession
    }
    public static func export(items: [ExportItem], to destination: URL, options: ExportOptions = ExportOptions(), progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard !items.isEmpty else { throw RecorderError.message("Select at least one recorded page to export audio.") }
        let working = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: working) }
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError.message("Could not create the audio presentation.")
        }
        var cursor = CMTime.zero
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let processed = working.appendingPathComponent("\(index).caf")
            try await AudioProcessing.renderPlayback(take: item.take, source: item.audioURL, to: processed,
                                                     matchLoudness: options.matchLoudness, fadeSeconds: options.boundaryFadeSeconds)
            let asset = AVURLAsset(url: processed)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw RecorderError.message("A selected take is missing its audio.") }
            let length = CMTimeMinimum(try await asset.load(.duration), CMTime(seconds: item.take.playbackDuration, preferredTimescale: 48_000))
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: cursor)
            cursor = cursor + length
            progress(Double(index + 1) / Double(items.count) * 0.2)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw RecorderError.message("Audio export is unavailable.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pdfrecorder-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        session.outputURL = temporary; session.outputFileType = .m4a
        try Task.checkCancellation()
        let handle = CancellationHandle(session: session)
        let reporter = Task {
            while !Task.isCancelled {
                progress(0.2 + Double(session.progress) * 0.8)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { reporter.cancel() }
        await withTaskCancellationHandler(operation: { await session.export() }, onCancel: { handle.session.cancelExport() })
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? RecorderError.message("Audio export failed.") }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
        progress(1)
    }
}
