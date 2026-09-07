import AVFoundation
import PDFRecorderCore

// Capture state is confined to `queue`; onFailure is installed and invoked on the main queue.
final class MicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Snapshot {
        var time = 0.0; var level = 0.0; var rmsDB = -100.0; var peak = 0.0
        var feedback: String {
            if time < 1 { return "Speak normally to check your microphone" }
            if peak >= 0.99 { return "Clipping · move farther from the microphone or reduce input volume" }
            if rmsDB < -60 { return "No speech detected · check the selected input" }
            if rmsDB < -35 { return "Too quiet · move closer or raise input volume" }
            return "Good level · microphone is receiving sound"
        }
    }
    private let queue = DispatchQueue(label: "org.pdfrecorder.microphone", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var clock: SampleClock?
    private var paused = false
    private var level = 0.0
    private var rmsDB = -100.0
    private var peak = 0.0
    private var failed = false
    private var observers: [NSObjectProtocol] = []
    var onFailure: ((String) -> Void)?

    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    var snapshot: Snapshot { queue.sync { Snapshot(time: clock?.duration ?? 0, level: level, rmsDB: rmsDB, peak: peak) } }

    func start(deviceID: String?, url: URL?) async throws {
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        guard permitted else { throw RecorderError.message("Microphone access is off. Enable PDF Recorder in System Settings → Privacy & Security → Microphone, then try again.") }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let device: AVCaptureDevice?
                    if let deviceID, !deviceID.isEmpty {
                        device = Self.devices.first { $0.uniqueID == deviceID }
                    } else { device = AVCaptureDevice.default(for: .audio) }
                    guard let device else { throw RecorderError.message("The selected microphone is unavailable. Connect a microphone or choose another input.") }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw RecorderError.message("This microphone could not be started.") }
                    session.addInput(input); session.addOutput(output)
                    output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                                            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                                            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.outputURL = url; self.clock = nil; self.audioFile = nil
                    self.paused = false; self.failed = false; self.level = 0; self.rmsDB = -100; self.peak = 0
                    self.session = session
                    self.observers = [
                        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
                            self?.reportFailure("Microphone capture was interrupted. The readable part of this take will be saved.")
                        },
                        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
                            self?.reportFailure("Microphone capture was interrupted. The readable part of this take will be saved.")
                        },
                        NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
                            self?.reportFailure("The microphone was disconnected. The readable part of this take will be saved.")
                        }
                    ]
                    session.startRunning()
                    guard session.isRunning else { throw RecorderError.message("The microphone did not start.") }
                    continuation.resume()
                } catch {
                    self.cleanUp()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func reportFailure(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(text) }
    }
    func setPaused(_ value: Bool) { queue.sync { paused = value; level = 0 } }
    func stop() async -> Double {
        await withCheckedContinuation { continuation in
            queue.async {
                let duration = self.clock?.duration ?? 0
                self.cleanUp()
                continuation.resume(returning: duration)
            }
        }
    }
    private func cleanUp() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        session?.stopRunning(); session = nil
        audioFile = nil; outputURL = nil; level = 0
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, !failed, session != nil else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: asbd) else { throw RecorderError.message("Unsupported microphone audio format.") }
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
            pcm.frameLength = AVAudioFrameCount(count)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
            guard status == noErr else { throw RecorderError.message("Could not read microphone audio (\(status)).") }
            if clock == nil { clock = SampleClock(sampleRate: format.sampleRate) }
            if audioFile == nil, let url = outputURL {
                var settings = format.settings
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsFloatKey] = false
                audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            guard clock?.sampleRate == format.sampleRate else { throw RecorderError.message("The microphone format changed. Start a new take to continue.") }
            try audioFile?.write(from: pcm)
            clock?.append(frames: count, paused: false)
            if let samples = pcm.floatChannelData?[0] {
                var sum = Float(0)
                var maximum = Float(0)
                for i in 0..<count { let sample = samples[i * Int(format.channelCount)]; sum += sample * sample; maximum = max(maximum, abs(sample)) }
                let rms = sqrt(sum / Float(count))
                rmsDB = Double(20 * log10(max(rms, 0.00001))); peak = max(Double(maximum), peak * 0.9)
                level = max(0, min(1, (rmsDB + 55) / 55))
            }
        } catch {
            failed = true
            reportFailure("Audio recording stopped: \(error.localizedDescription)")
        }
    }
}
