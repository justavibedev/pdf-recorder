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
    public static func load(at root: URL) throws -> ProjectManifest {
        var m = try decode(ProjectManifest.self, from: root.appendingPathComponent("manifest.json"))
        guard (1...2).contains(m.version) else { throw RecorderError.message("This project uses an unsupported format version (\(m.version)).") }
        m.version = 2
        guard !m.pages.isEmpty, m.pages.count <= 100_000, m.sourcePDF == "source.pdf" else { throw RecorderError.message("The project has an invalid page list or source path.") }
        _ = try location(m.sourcePDF, in: root)
        var ids = Set<UUID>()
        for page in m.pages {
            if let target = page.targetSeconds, !target.isFinite || target < 0 || target > 86_400 {
                throw RecorderError.message("A page has an invalid presentation target.")
            }
            if let selected = page.selectedTakeID, !page.takes.contains(where: { $0.id == selected }) {
                throw RecorderError.message("A page refers to a missing selected take.")
            }
            for take in page.takes {
                guard ids.insert(take.id).inserted, take.duration.isFinite, take.duration > 0,
                      take.audioPath == "takes/\(take.id.uuidString)/audio.caf",
                      take.eventsPath == "takes/\(take.id.uuidString)/events.json",
                      valid(take.initialViewport) else { throw RecorderError.message("A take contains invalid metadata.") }
                for path in [take.audioPath, take.eventsPath] {
                    guard FileManager.default.fileExists(atPath: try location(path, in: root).path) else {
                        throw RecorderError.message("A recording file is missing: \(path)")
                    }
                }
            }
        }
        return m
    }
    public static func events(for take: Take, at root: URL) throws -> [TimedEvent] {
        let events = try decode([TimedEvent].self, from: location(take.eventsPath, in: root))
        try validate(events)
        return events
    }
    private static func valid(_ p: Point) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) < 1e6 && abs(p.y) < 1e6 }
    private static func valid(_ v: Viewport) -> Bool { v.zoom.isFinite && (1...8).contains(v.zoom) && valid(v.offset) }
    public static func validate(_ events: [TimedEvent]) throws {
        var last = 0.0
        for event in events {
            var okay = event.time.isFinite && event.time >= last
            switch event.action {
            case .pointer(let p): okay = okay && (p.map(valid) ?? true)
            case .viewport(let v): okay = okay && valid(v)
            case .beginStroke(let s), .restoreStroke(let s):
                okay = okay && s.width.isFinite && s.width > 0 && s.width < 1 && s.points.allSatisfy(valid)
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
