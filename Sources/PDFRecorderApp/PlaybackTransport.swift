import AVFoundation

/// A small transport seam allows queue/loop/controller tests without opening audio devices.
protocol PlaybackTransport: AnyObject {
    var currentTime: TimeInterval { get set }
    var rate: Float { get set }
    var enableRate: Bool { get set }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func pause()
    func stop()
    @discardableResult func prepareToPlay() -> Bool
}
extension AVAudioPlayer: PlaybackTransport {}
