import Foundation
@preconcurrency import AVFoundation

public struct WaveformBin: Equatable, Sendable {
    public var peak: Float
    public var rms: Float
    public var clipped: Bool
    public init(peak: Float, rms: Float, clipped: Bool) { self.peak = peak; self.rms = rms; self.clipped = clipped }
}

public struct WaveformAnalysis: Equatable, Sendable {
    public var bins: [WaveformBin]
    public var duration: Double
    public var rmsDB: Double
    public var peak: Float
    public var clipped: Bool
    public var isSilent: Bool { rmsDB < -50 }
    public var isQuiet: Bool { rmsDB < -30 }
    public var feedback: String {
        if clipped { return "Clipping detected — lower the microphone input level." }
        if isSilent { return "No clear signal detected." }
        if isQuiet { return "The recording is quiet." }
        return "Signal level looks good."
    }
}

public enum AudioAnalysis {
    /// Reads fixed-size blocks; memory depends on waveform resolution, not recording length.
    public static func analyze(url: URL, binCount: Int = 600, trim: TakeLoopRange? = nil) throws -> WaveformAnalysis {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let trimStart = trim?.start ?? 0, trimEnd = trim?.end ?? (Double(file.length) / rate)
        guard trimStart.isFinite, trimEnd.isFinite, trimStart >= 0, trimEnd >= trimStart else {
            throw RecorderError.message("The audio trim range is invalid.")
        }
        let start = AVAudioFramePosition(min(Double(file.length), trimStart * rate))
        let end = AVAudioFramePosition(min(Double(file.length), trimEnd * rate))
        let count = end - start
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw RecorderError.message("The audio has no readable samples.")
        }
        let binCount = max(1, min(8192, min(binCount, Int(count))))
        var squares = Array(repeating: 0.0, count: binCount)
        var samples = Array(repeating: 0, count: binCount)
        var peaks = Array(repeating: Float(0), count: binCount)
        var sum = 0.0
        var offset: Int64 = 0
        file.framePosition = start
        let channels = Int(file.processingFormat.channelCount)
        while offset < count {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, count - offset)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(binCount - 1, Int(Double(offset + Int64(frame)) / Double(count) * Double(binCount)))
                for channel in 0..<channels {
                    let value = data[channel][frame].isFinite ? data[channel][frame] : 0
                    let square = Double(value) * Double(value)
                    squares[bin] += square; sum += square; samples[bin] += 1
                    peaks[bin] = max(peaks[bin], abs(value))
                }
            }
            offset += Int64(buffer.frameLength)
        }
        let rms = sqrt(sum / Double(max(1, offset * Int64(channels))))
        return WaveformAnalysis(bins: (0..<binCount).map {
            WaveformBin(peak: peaks[$0], rms: Float(sqrt(squares[$0] / Double(max(1, samples[$0])))), clipped: peaks[$0] >= 0.995)
        }, duration: Double(offset) / rate, rmsDB: 20 * log10(max(rms, 0.000_000_1)), peak: peaks.max() ?? 0, clipped: peaks.contains { $0 >= 0.995 })
    }
}

public enum AudioProcessing {
    /// RMS matching targets -20 dBFS with at most 12 dB of automatic boost and 1 dB peak headroom.
    /// This is speech-level matching, not an integrated LUFS meter.
    public static func gain(take: Take, analysis: WaveformAnalysis, matchLoudness: Bool) -> Float {
        let manual = min(24, max(-60, take.gainDB ?? 0))
        var automatic = 0.0
        if matchLoudness && !analysis.isSilent {
            let headroom = -1 - 20 * log10(max(Double(analysis.peak), 0.000_000_1))
            automatic = min(12, min(-20 - analysis.rmsDB, headroom))
        }
        return Float(pow(10, (manual + automatic) / 20))
    }

    public static func fadeGain(at time: Double, duration: Double, fadeSeconds: Double = 0.01) -> Float {
        let fade = min(max(0, fadeSeconds), duration / 2)
        guard fade > 0 else { return 1 }
        return Float(max(0, min(1, min(time / fade, (duration - time) / fade))))
    }

    /// A disposable, trimmed PCM clip for both playback and export. Source samples are never changed.
    /// Caller runs this on a background task and owns the resulting temporary file's lifetime.
    public static func renderPlayback(take: Take, source: URL, to destination: URL, matchLoudness: Bool,
                                      fadeSeconds: Double = 0.01) async throws {
        try Task.checkCancellation()
        guard take.duration.isFinite, take.playbackStart.isFinite, take.playbackEnd.isFinite,
              take.playbackDuration > 0, (take.gainDB ?? 0).isFinite, fadeSeconds.isFinite else {
            throw RecorderError.message("The take's trim range or volume setting is invalid.")
        }
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            throw RecorderError.message("Playback processing must write to a temporary file, preserving the source audio.")
        }
        let analysis = try AudioAnalysis.analyze(url: source, binCount: 1, trim: TakeLoopRange(start: take.playbackStart, end: take.playbackEnd))
        let multiplier = gain(take: take, analysis: analysis, matchLoudness: matchLoudness)
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let start = AVAudioFramePosition(min(Double(input.length), take.playbackStart * format.sampleRate))
        let end = AVAudioFramePosition(min(Double(input.length), take.playbackEnd * format.sampleRate))
        let count = end - start
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw RecorderError.message("The trimmed take has no readable audio.")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        input.framePosition = start
        var offset: Int64 = 0
        let duration = Double(count) / format.sampleRate
        while offset < count {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, count - offset)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { throw RecorderError.message("Audio ended before the trim range.") }
            for frame in 0..<Int(buffer.frameLength) {
                let gain = multiplier * fadeGain(at: Double(offset + Int64(frame)) / format.sampleRate, duration: duration, fadeSeconds: fadeSeconds)
                for channel in 0..<Int(format.channelCount) { data[channel][frame] = min(1, max(-1, data[channel][frame] * gain)) }
            }
            try output.write(from: buffer)
            offset += Int64(buffer.frameLength)
        }
        completed = true
    }
}
