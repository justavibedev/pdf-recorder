import Foundation

public enum ExportPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, standard, high
    public var id: String { rawValue }
    public var label: String {
        switch self { case .small: return "Small upload"; case .standard: return "Standard"; case .high: return "High quality" }
    }
    public var width: Int { self == .small ? 1280 : 1920 }
    public var height: Int { self == .small ? 720 : 1080 }
    public var videoBitRate: Int {
        switch self { case .small: return 2_000_000; case .standard: return 6_000_000; case .high: return 12_000_000 }
    }
}

public struct ExportOptions: Equatable, Sendable {
    public var preset: ExportPreset
    public var matchLoudness: Bool
    public var boundaryFadeSeconds: Double
    public init(preset: ExportPreset = .standard, matchLoudness: Bool = false, boundaryFadeSeconds: Double = 0.01) {
        self.preset = preset; self.matchLoudness = matchLoudness; self.boundaryFadeSeconds = boundaryFadeSeconds
    }
    /// Budget estimate, not a file-size guarantee: H.264 content complexity and the muxer affect final size.
    public func estimatedBytes(duration: Double, audioOnly: Bool = false) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let estimate = ceil(duration * Double((audioOnly ? 0 : preset.videoBitRate) + 192_000) / 8 * 1.03)
        return estimate >= Double(Int64.max) ? Int64.max : Int64(estimate)
    }
    public static func estimatedSecondsRemaining(progress: Double, elapsed: Double) -> Double? {
        guard progress.isFinite, elapsed.isFinite, progress > 0.01, progress < 1, elapsed >= 1 else { return nil }
        return elapsed * (1 - progress) / progress
    }
}
