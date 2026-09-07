import Foundation
import CryptoKit
@preconcurrency import AVFoundation

/// Disk-backed, disposable playback audio. A returned URL is owned by this cache and must not be deleted by callers.
/// Completed clips are bounded to three entries and `maxBytes`; one oversized newest clip is allowed by itself.
/// Callers should open a returned clip promptly: a later preparation may evict older clips.
public actor PlaybackAudioCache {
    public let directory: URL
    public let maxBytes: Int64
    private let maximumEntries = 3
    private var initialized = false
    private var clearing = false
    private var revision = 0
    private var workers: [UUID: Task<Void, Error>] = [:]

    public init(directory: URL, maxBytes: Int64 = 512 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = max(1, maxBytes)
    }

    public func preparedURL(take: Take, source: URL, matchLoudness: Bool) async throws -> URL {
        try Task.checkCancellation()
        guard !clearing else { throw CancellationError() }
        try initialize()
        let requestRevision = revision
        let fingerprint = try Self.fingerprint(take: take, source: source, matchLoudness: matchLoudness)
        let destination = directory.appendingPathComponent("clip-\(fingerprint).caf")
        if FileManager.default.fileExists(atPath: destination.path) {
            // A corrupt disposable clip should be regenerated, never reported as a lost source take.
            if (try? AVAudioFile(forReading: destination).length) ?? 0 > 0 {
                try touch(destination)
                try prune(keeping: destination)
                return destination
            }
            try? FileManager.default.removeItem(at: destination)
        }
        let pending = directory.appendingPathComponent(".pending-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: pending) }
        let worker = Task.detached(priority: .userInitiated) {
            try await AudioProcessing.renderPlayback(take: take, source: source, to: pending, matchLoudness: matchLoudness)
        }
        let requestID = UUID()
        workers[requestID] = worker
        defer { workers.removeValue(forKey: requestID) }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard requestRevision == revision, !clearing else { throw CancellationError() }
        // The source might have been replaced while a long clip was processing.
        guard try Self.fingerprint(take: take, source: source, matchLoudness: matchLoudness) == fingerprint else {
            throw RecorderError.message("The source audio changed while preparing playback. Try again.")
        }
        // Concurrent requests use distinct temporary files. Only complete output gets the stable cache name.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: pending, to: destination)
        }
        try touch(destination)
        try prune(keeping: destination)
        return destination
    }

    /// Cancels preparations and removes cache-owned files. Unrelated directory contents are preserved.
    public func removeAll() async throws {
        guard !clearing else { return }
        clearing = true; revision += 1
        defer { clearing = false; initialized = false }
        let active = Array(workers.values)
        for worker in active { worker.cancel() }
        for worker in active { _ = try? await worker.value }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if Self.isClip(url) || Self.isPending(url) {
                try FileManager.default.removeItem(at: url)
            }
        }
        if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { try FileManager.default.removeItem(at: directory) }
    }

    private func initialize() throws {
        guard !initialized else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Crash leftovers do not count as reusable clips. Never disturb a recent writer from another app instance.
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) where Self.isPending(url) {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
        initialized = true
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func prune(keeping newest: URL) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var entries: [(url: URL, size: Int64, accessed: Date)] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            guard Self.isClip(url) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            entries.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        entries.sort { $0.accessed < $1.accessed }
        var count = entries.count
        var bytes = entries.reduce(Int64(0)) { $0 + $1.size }
        // Directory enumeration can return file-reference/base URLs with different URL equality semantics.
        // Cache filenames are unique within this directory, so compare those when protecting the current clip.
        for entry in entries where entry.url.lastPathComponent != newest.lastPathComponent {
            guard count > maximumEntries || bytes > maxBytes else { break }
            try FileManager.default.removeItem(at: entry.url)
            count -= 1; bytes -= entry.size
        }
    }

    private static func isClip(_ url: URL) -> Bool {
        guard url.pathExtension == "caf", url.lastPathComponent.hasPrefix("clip-") else { return false }
        let digest = url.deletingPathExtension().lastPathComponent.dropFirst(5)
        return digest.count == 64 && digest.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private static func isPending(_ url: URL) -> Bool {
        guard url.pathExtension == "caf", url.lastPathComponent.hasPrefix(".pending-") else { return false }
        return UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(9))) != nil
    }

    private static func fingerprint(take: Take, source: URL, matchLoudness: Bool) throws -> String {
        let resolved = source.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try resolved.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard attributes.isRegularFile == true else { throw RecorderError.message("The source audio is not a readable file.") }
        // Explicit algorithm revision prevents reuse after processing behavior changes.
        let identity = ["playback-pcm-v2", resolved.path, String(attributes.fileSize ?? 0),
                        String((attributes.contentModificationDate ?? .distantPast).timeIntervalSinceReferenceDate.bitPattern),
                        String(take.playbackStart.bitPattern), String(take.playbackEnd.bitPattern),
                        String((take.gainDB ?? 0).bitPattern), matchLoudness ? "matched" : "original", "fade=0.01"]
        let data = try JSONEncoder().encode(identity)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
