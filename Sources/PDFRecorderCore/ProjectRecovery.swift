import Foundation

public struct TrashedTake: Codable, Identifiable, Equatable, Sendable {
    public var page: Int
    public var take: Take
    public var deletedAt: Date
    public var id: UUID { take.id }
    public init(page: Int, take: Take) { self.page = page; self.take = take; deletedAt = Date() }
}
public struct ProjectSnapshot: Codable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var reason: String
    public var manifest: ProjectManifest
    public init(manifest: ProjectManifest, reason: String) { id = UUID(); date = Date(); self.reason = reason; self.manifest = manifest }
}
public struct StorageInventory: Sendable {
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var unusedTakeBytes: Int64
    public var trash: [TrashedTake]
    public var snapshots: [ProjectSnapshot]
    public var hasActiveTake: Bool
    public var unavailable: [TrashedTake]
    public var setAsideRecordings: [String]
}

public enum ProjectRecovery {
    public static func trash(at root: URL) throws -> [TrashedTake] { try entries("trash.json", at: root) }
    public static func unavailable(at root: URL) throws -> [TrashedTake] { try entries("unavailable-takes.json", at: root) }
    private static func entries(_ name: String, at root: URL) throws -> [TrashedTake] {
        let url = root.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? try ProjectStore.decode([TrashedTake].self, from: url) : []
    }
    public static func trashTake(_ id: UUID, page: Int, manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        guard manifest.pages.indices.contains(page), let take = manifest.pages[page].takes.first(where: { $0.id == id }) else { throw RecorderError.message("The take is no longer available.") }
        var deleted = try trash(at: root)
        if !deleted.contains(where: { $0.id == id }) { deleted.append(.init(page: page, take: take)) }
        // Journal the deletion first. An interrupted save may leave a duplicate entry,
        // but can never make the only copy of a take disappear.
        try ProjectStore.write(deleted, to: root.appendingPathComponent("trash.json"))
        var updated = manifest; updated.pages[page].delete(id)
        try ProjectStore.save(updated, at: root)
        return updated
    }
    public static func restoreTake(_ id: UUID, manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        var deleted = try trash(at: root)
        guard let item = deleted.first(where: { $0.id == id }), manifest.pages.indices.contains(item.page) else { throw RecorderError.message("This deleted take cannot be restored.") }
        try checkMedia(item.take, at: root)
        var updated = manifest
        if !updated.pages[item.page].takes.contains(where: { $0.id == id }) { updated.pages[item.page].add(item.take) }
        try ProjectStore.save(updated, at: root)
        deleted.removeAll { $0.id == id }; try ProjectStore.write(deleted, to: root.appendingPathComponent("trash.json"))
        return updated
    }
    @discardableResult public static func snapshot(_ manifest: ProjectManifest, reason: String, at root: URL) throws -> ProjectSnapshot {
        let snapshot = ProjectSnapshot(manifest: manifest, reason: reason)
        let directory = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProjectStore.write(snapshot, to: directory.appendingPathComponent(snapshot.id.uuidString + ".json"))
        return snapshot
    }
    public static func snapshots(at root: URL) throws -> [ProjectSnapshot] {
        let directory = root.appendingPathComponent("snapshots", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try ProjectStore.decode(ProjectSnapshot.self, from: $0) }.sorted { $0.date > $1.date }
    }
    public static func restoreSnapshot(_ snapshot: ProjectSnapshot, current: ProjectManifest, at root: URL) throws -> ProjectManifest {
        guard snapshot.manifest.id == current.id, snapshot.manifest.pages.count == current.pages.count else { throw RecorderError.message("This snapshot belongs to a different project.") }
        for take in snapshot.manifest.pages.flatMap(\.takes) { try checkMedia(take, at: root) }
        try self.snapshot(current, reason: "Before restoring \(snapshot.reason)", at: root)
        var deleted = try trash(at: root)
        let restoringIDs = Set(snapshot.manifest.pages.flatMap(\.takes).map(\.id))
        for (page, record) in current.pages.enumerated() {
            for take in record.takes where !restoringIDs.contains(take.id) && !deleted.contains(where: { $0.id == take.id }) { deleted.append(.init(page: page, take: take)) }
        }
        try ProjectStore.write(deleted, to: root.appendingPathComponent("trash.json"))
        try ProjectStore.save(snapshot.manifest, at: root)
        deleted.removeAll { restoringIDs.contains($0.id) }
        try ProjectStore.write(deleted, to: root.appendingPathComponent("trash.json"))
        return snapshot.manifest
    }
    public static func removeSnapshot(_ id: UUID, at root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("snapshots/\(id.uuidString).json"))
    }
    public static func purgeTake(_ id: UUID, manifest: ProjectManifest, at root: URL) throws {
        guard !manifest.pages.flatMap(\.takes).contains(where: { $0.id == id }) else { throw RecorderError.message("This take is still in use.") }
        guard !(try snapshots(at: root)).contains(where: { $0.manifest.pages.flatMap(\.takes).contains(where: { $0.id == id }) }) else {
            throw RecorderError.message("A saved snapshot still uses this take. Remove that snapshot before permanently deleting the take.")
        }
        var deleted = try trash(at: root)
        guard let take = deleted.first(where: { $0.id == id })?.take else { return }
        for path in [take.audioPath, take.eventsPath] {
            let url = try ProjectStore.location(path, in: root)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        deleted.removeAll { $0.id == id }; try ProjectStore.write(deleted, to: root.appendingPathComponent("trash.json"))
    }
    /// Isolates missing takes without dropping their metadata or changing any source files.
    public static func isolateMissingMedia(_ manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        var updated = manifest, missing = try unavailable(at: root)
        for (page, record) in manifest.pages.enumerated() {
            for take in record.takes where !mediaExists(take, at: root) {
                if !missing.contains(where: { $0.id == take.id }) { missing.append(.init(page: page, take: take)) }
                updated.pages[page].delete(take.id)
            }
        }
        try snapshot(manifest, reason: "Before isolating unavailable files", at: root)
        try ProjectStore.write(missing, to: root.appendingPathComponent("unavailable-takes.json"))
        try ProjectStore.save(updated, at: root)
        return updated
    }
    public static func retryUnavailable(_ manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        var updated = manifest, remaining: [TrashedTake] = []
        for item in try unavailable(at: root) {
            if updated.pages.indices.contains(item.page), mediaExists(item.take, at: root) {
                if !updated.pages[item.page].takes.contains(where: { $0.id == item.id }) { updated.pages[item.page].takes.append(item.take) }
                if updated.pages[item.page].selectedTakeID == nil { updated.pages[item.page].selectedTakeID = item.id }
            } else { remaining.append(item) }
        }
        try ProjectStore.save(updated, at: root)
        try ProjectStore.write(remaining, to: root.appendingPathComponent("unavailable-takes.json"))
        return updated
    }
    public static func recoverSetAside(_ name: String, manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        guard name.hasPrefix("unfinished-"), name.hasSuffix(".json"), !name.contains("/"),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("active-take.json").path) else {
            throw RecorderError.message("Recover the active interrupted take first, then recover this saved-aside recording.")
        }
        let source = try ProjectStore.location(name, in: root), active = root.appendingPathComponent("active-take.json")
        try FileManager.default.moveItem(at: source, to: active)
        do { return try ProjectStore.recover(at: root, manifest: manifest) }
        catch { if FileManager.default.fileExists(atPath: active.path) { try? FileManager.default.moveItem(at: active, to: source) }; throw error }
    }
    public static func inspect(manifest: ProjectManifest, at root: URL) throws -> StorageInventory {
        let selected = Set(manifest.selectedTakes.map { $0.take.id })
        let unused = try manifest.pages.flatMap(\.takes).filter { !selected.contains($0.id) }.reduce(Int64(0)) { value, take in
            value + (try fileSize(ProjectStore.location(take.audioPath, in: root))) + (try fileSize(ProjectStore.location(take.eventsPath, in: root)))
        }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        return .init(totalBytes: try directorySize(root), availableBytes: free, unusedTakeBytes: unused,
                     trash: try trash(at: root), snapshots: try snapshots(at: root),
                     hasActiveTake: FileManager.default.fileExists(atPath: root.appendingPathComponent("active-take.json").path), unavailable: try unavailable(at: root),
                     setAsideRecordings: try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("unfinished-") && $0.hasSuffix(".json") }.sorted())
    }
    public static func mediaExists(_ take: Take, at root: URL) -> Bool {
        [take.audioPath, take.eventsPath].allSatisfy { path in (try? ProjectStore.location(path, in: root)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }
    private static func checkMedia(_ take: Take, at root: URL) throws {
        guard mediaExists(take, at: root) else { throw RecorderError.message("A recording file is missing. Restore its files to the project before trying again.") }
    }
    private static func fileSize(_ url: URL) throws -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    private static func directorySize(_ root: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants() }
            else if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        return size
    }
}
