import Foundation
import PDFKit
import AVFoundation

public struct ActiveTake: Codable {
    public var page: Int
    public var take: Take
    public var events: [TimedEvent]
    public init(page: Int, take: Take, events: [TimedEvent]) { self.page = page; self.take = take; self.events = events }
}

public enum ProjectStore {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func location(_ relativePath: String, in root: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard !relativePath.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else {
            throw RecorderError.message("This project contains an invalid file path.")
        }
        var componentURL = root
        for component in relativePath.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            if (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw RecorderError.message("Project files cannot use symbolic links.")
            }
        }
        return url
    }
    public static func create(at root: URL, source: URL, title: String, pageCount: Int) throws -> ProjectManifest {
        guard (1...100_000).contains(pageCount) else { throw RecorderError.message("The PDF must contain between 1 and 100,000 pages.") }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw RecorderError.message("A project already exists at this location.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("source.pdf"))
            let manifest = ProjectManifest(title: title, pageCount: pageCount)
            try save(manifest, at: root)
            return manifest
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    public static func save(_ manifest: ProjectManifest, at root: URL) throws {
        try write(manifest, to: root.appendingPathComponent("manifest.json"))
    }
    /// Save current in-memory work to a new location without writing the original.
    public static func saveCopy(from root: URL, to destination: URL, manifest: ProjectManifest) throws {
        let original = root.standardizedFileURL.resolvingSymlinksInPath(), target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard original != target, !target.path.hasPrefix(original.path + "/"), !original.path.hasPrefix(target.path + "/") else {
            throw RecorderError.message("Choose a location outside the current project package.")
        }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".pdfrecorder-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: root, to: staged)
        // A copied read-only project must become editable at its new location.
        // Change the staged copy only; never follow symlinks or touch the source.
        var copiedURLs = [staged]
        if let enumerator = FileManager.default.enumerator(at: staged, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                if (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { enumerator.skipDescendants() }
                else { copiedURLs.append(url) }
            }
        }
        for url in copiedURLs {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let directory = attributes[.type] as? FileAttributeType == .typeDirectory
            try FileManager.default.setAttributes([.posixPermissions: permissions | (directory ? 0o700 : 0o600)], ofItemAtPath: url.path)
        }
        try save(manifest, at: staged)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
    }
    public static func load(at root: URL, allowingMissingMedia: Bool = false) throws -> ProjectManifest {
        var m = try decode(ProjectManifest.self, from: root.appendingPathComponent("manifest.json"))
        guard (1...4).contains(m.version) else { throw RecorderError.message("This project uses an unsupported format version (\(m.version)).") }
        m.version = 4
        try validateDocuments(m, at: root)
        var ids = Set<UUID>()
        for page in m.pages {
            if let target = page.targetSeconds, !target.isFinite || target < 0 || target > 86_400 {
                throw RecorderError.message("A page has an invalid presentation target.")
            }
            if let selected = page.selectedTakeID, !page.takes.contains(where: { $0.id == selected }) {
                throw RecorderError.message("A page refers to a missing selected take.")
            }
            for take in page.takes {
                try validateTake(take)
                guard ids.insert(take.id).inserted, take.duration.isFinite, take.duration > 0,
                      take.audioPath == "takes/\(take.id.uuidString)/audio.caf",
                      take.eventsPath == "takes/\(take.id.uuidString)/events.json",
                      valid(take.initialViewport) else { throw RecorderError.message("A take contains invalid metadata.") }
                for path in [take.audioPath, take.eventsPath] {
                    let url = try location(path, in: root)
                    guard allowingMissingMedia || FileManager.default.fileExists(atPath: url.path) else {
                        throw RecorderError.message("A recording file is missing: \(path)")
                    }
                }
            }
        }
        return m
    }
    public static func events(for take: Take, at root: URL) throws -> [TimedEvent] {
        let events = try EventLogReader.readAll(url: location(take.eventsPath, in: root))
        try validate(events)
        return events
    }
    private static func valid(_ p: Point) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) < 1e6 && abs(p.y) < 1e6 }
    private static func valid(_ v: Viewport) -> Bool { v.zoom.isFinite && (1...8).contains(v.zoom) && valid(v.offset) }
    public static func validateTake(_ take: Take) throws {
        let start = take.trimStart ?? 0, end = take.trimEnd ?? take.duration, gain = take.gainDB ?? 0
        guard start.isFinite, end.isFinite, gain.isFinite, start >= 0, end <= take.duration, end - start >= 0.05,
              (-60...24).contains(gain) else { throw RecorderError.message("A take has invalid trim or volume settings.") }
        if let loop = take.loopRange {
            guard loop.start.isFinite, loop.end.isFinite, loop.start >= start, loop.end <= end, loop.end > loop.start else {
                throw RecorderError.message("A review loop is outside the trimmed take.")
            }
        }
        for marker in take.reviewMarkers ?? [] {
            guard marker.time.isFinite, marker.time >= 0, marker.time <= take.duration else { throw RecorderError.message("A review marker has an invalid timestamp.") }
        }
    }
    public static func validate(_ events: [TimedEvent]) throws {
        var last = 0.0
        for event in events {
            var okay = event.time.isFinite && event.time >= last
            switch event.action {
            case .pointer(let p): okay = okay && (p.map(valid) ?? true)
            case .viewport(let v): okay = okay && valid(v)
            case .beginStroke(let s), .restoreStroke(let s, _):
                okay = okay && s.width.isFinite && s.width > 0 && s.width < 1 && s.points.allSatisfy(valid)
                if let opacity = s.opacity { okay = okay && opacity.isFinite && (0...1).contains(opacity) }
                if case .restoreStroke(_, let index) = event.action, let index { okay = okay && index >= 0 }
            case .extendStroke(_, let p): okay = okay && valid(p)
            case .removeStroke: break
            }
            guard okay else { throw RecorderError.message("A recording contains invalid timeline data.") }
            last = event.time
        }
    }
    public static func prepare(_ take: Take, at root: URL) throws -> URL {
        let audio = try location(take.audioPath, in: root)
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        return audio
    }
    public static func commit(_ take: Take, events: [TimedEvent], page: Int, manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        guard manifest.pages.indices.contains(page), take.duration > 0 else { throw RecorderError.message("This take is empty.") }
        try validate(events)
        try write(events, to: location(take.eventsPath, in: root))
        var updated = manifest
        updated.pages[page].add(take)
        try save(updated, at: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("active-take.json"))
        try? FileManager.default.removeItem(at: location(take.eventsPath, in: root).deletingPathExtension().appendingPathExtension("ndjson"))
        return updated
    }
    @discardableResult public static func journal(_ active: ActiveTake, from eventIndex: Int = 0, at root: URL) throws -> Int {
        let url = try location(active.take.eventsPath, in: root).deletingPathExtension().appendingPathExtension("ndjson")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw RecorderError.message("Could not create the recovery journal.") }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if eventIndex == 0 { try handle.truncate(atOffset: 0) }
        try handle.seekToEnd()
        var batch = Data()
        for event in active.events.dropFirst(eventIndex) { batch.append(try encoder.encode(event)); batch.append(10) }
        try handle.write(contentsOf: batch)
        try handle.synchronize()
        var metadata = active; metadata.events = []
        try write(metadata, to: root.appendingPathComponent("active-take.json"))
        return active.events.count
    }
    public static func recover(at root: URL, manifest: ProjectManifest) throws -> ProjectManifest {
        let url = root.appendingPathComponent("active-take.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return manifest }
        var active = try decode(ActiveTake.self, from: url)
        guard !manifest.pages.flatMap(\.takes).contains(where: { $0.id == active.take.id }) else {
            try FileManager.default.removeItem(at: url); return manifest
        }
        let audio = try AVAudioFile(forReading: location(active.take.audioPath, in: root))
        let journalURL = try location(active.take.eventsPath, in: root).deletingPathExtension().appendingPathExtension("ndjson")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let data = try Data(contentsOf: journalURL)
            // Only the last incomplete line may be discarded after a crash.
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            active.events = try lines.dropLast().map { try JSONDecoder().decode(TimedEvent.self, from: Data($0)) }
        }
        active.take.duration = Double(audio.length) / audio.processingFormat.sampleRate
        active.take.recovered = true
        let events = active.events.filter { $0.time <= active.take.duration }
        return try commit(active.take, events: events, page: active.page, manifest: manifest, at: root)
    }
    /// Keep an unreadable/unfinished recording intact while allowing a fresh take.
    public static func setAsideActiveTake(at root: URL) throws {
        let source = root.appendingPathComponent("active-take.json")
        let destination = root.appendingPathComponent("unfinished-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
