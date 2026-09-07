import Foundation

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct Viewport: Codable, Equatable, Sendable {
    public var zoom: Double
    public var offset: Point
    public init(zoom: Double = 1, offset: Point = Point(0, 0)) {
        self.zoom = zoom; self.offset = offset
    }
}

public enum InkTool: String, Codable, CaseIterable, Sendable {
    case pointer, pen, highlighter, eraser, pan, line, arrow, rectangle, ellipse, text, selectText
}

public enum AnnotationShape: String, Codable, Sendable { case line, arrow, rectangle, ellipse, text }

public struct Stroke: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tool: InkTool
    public var color: String
    public var width: Double
    public var points: [Point]
    public var opacity: Double?
    public var shape: AnnotationShape?
    public var text: String?
    public init(id: UUID = UUID(), tool: InkTool, color: String, width: Double, points: [Point], opacity: Double? = nil, shape: AnnotationShape? = nil, text: String? = nil) {
        self.id = id; self.tool = tool; self.color = color; self.width = width; self.points = points
        self.opacity = opacity; self.shape = shape; self.text = text
    }
}

public enum SceneAction: Codable, Equatable, Sendable {
    case pointer(Point?)
    case viewport(Viewport)
    case beginStroke(Stroke)
    case extendStroke(UUID, Point)
    case removeStroke(UUID)
    case restoreStroke(Stroke)
}

public struct TimedEvent: Codable, Equatable, Sendable {
    public var time: Double
    public var action: SceneAction
    public init(time: Double, action: SceneAction) { self.time = time; self.action = action }
}

public struct Scene: Equatable, Sendable {
    public var viewport = Viewport()
    public var pointer: Point?
    public var strokes: [Stroke] = []
    public init(viewport: Viewport = Viewport()) { self.viewport = viewport }
    public mutating func apply(_ action: SceneAction) {
        switch action {
        case .pointer(let p): pointer = p
        case .viewport(let v): viewport = v
        case .beginStroke(let s), .restoreStroke(let s):
            if !strokes.contains(where: { $0.id == s.id }) { strokes.append(s) }
        case .extendStroke(let id, let p):
            if let i = strokes.firstIndex(where: { $0.id == id }) { strokes[i].points.append(p) }
        case .removeStroke(let id): strokes.removeAll { $0.id == id }
        }
    }
}

/// Retains a bounded set of scene checkpoints so repeated long-take seeks avoid replaying the full log.
public struct Timeline {
    public let events: [TimedEvent]
    public private(set) var scene: Scene
    private var index = 0
    private var previousTime = -Double.infinity
    private let initialViewport: Viewport
    private var checkpoints: [(index: Int, scene: Scene, cost: Int)] = []
    private let checkpointStride: Int
    public var checkpointCount: Int { checkpoints.count }
    public init(events: [TimedEvent], initialViewport: Viewport) {
        self.events = events; self.initialViewport = initialViewport
        checkpointStride = max(256, Int(ceil(Double(events.count) / 48)))
        scene = Scene(viewport: initialViewport)
    }
    public mutating func seek(to time: Double) -> Scene {
        if time < previousTime {
            if let checkpoint = checkpoints.last(where: { $0.index > 0 && events[$0.index - 1].time <= time }) {
                index = checkpoint.index; scene = checkpoint.scene
            } else { index = 0; scene = Scene(viewport: initialViewport) }
        }
        while index < events.count && events[index].time <= time {
            scene.apply(events[index].action); index += 1
            if index % checkpointStride == 0 && !checkpoints.contains(where: { $0.index == index }) {
                // Count retained points conservatively even when Swift shares unchanged arrays.
                // Dense drawings cannot turn checkpointing into an unbounded memory multiplier.
                let cost = scene.strokes.reduce(0) { $0 + $1.points.count + 16 }
                let budget = 2_000_000
                if cost <= budget {
                    checkpoints.append((index, scene, cost)); checkpoints.sort { $0.index < $1.index }
                    while checkpoints.reduce(0, { $0 + $1.cost }) > budget {
                        checkpoints.remove(at: checkpoints.count > 2 ? 1 : 0)
                    }
                }
            }
        }
        previousTime = time
        return scene
    }
}

public enum TakeReviewStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case unreviewed, ready, needsCorrection
    public var id: String { rawValue }
    public var label: String {
        switch self { case .unreviewed: return "Unreviewed"; case .ready: return "Ready"; case .needsCorrection: return "Needs correction" }
    }
}

public struct ReviewMarker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String
    public init(id: UUID = UUID(), time: Double, label: String) { self.id = id; self.time = time; self.label = label }
}

public struct TakeLoopRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct Take: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: Double
    public var initialViewport: Viewport
    public var audioPath: String
    public var eventsPath: String
    public var recovered: Bool
    public var trimStart: Double?
    public var trimEnd: Double?
    public var name: String?
    public var favorite: Bool?
    public var reviewStatus: TakeReviewStatus?
    public var reviewMarkers: [ReviewMarker]?
    public var loopRange: TakeLoopRange?
    public var gainDB: Double?
    public var playbackStart: Double { min(max(0, trimStart ?? 0), max(0, duration)) }
    public var playbackEnd: Double { min(max(playbackStart, trimEnd ?? duration), max(0, duration)) }
    public var playbackDuration: Double { max(0, playbackEnd - playbackStart) }
    public var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Take" : value
    }
    public init(id: UUID = UUID(), duration: Double = 0, initialViewport: Viewport = Viewport(), recovered: Bool = false) {
        self.id = id; createdAt = Date(); self.duration = duration
        self.initialViewport = initialViewport; self.recovered = recovered
        audioPath = "takes/\(id.uuidString)/audio.caf"
        eventsPath = "takes/\(id.uuidString)/events.json"
    }
}

public struct PageRecord: Codable, Equatable, Sendable {
    public var takes: [Take] = []
    public var selectedTakeID: UUID?
    public var title: String?
    public var notes: String?
    public var bookmarked: Bool?
    public var targetSeconds: Double?
    public var includedInExport: Bool?
    public var selectedTake: Take? { takes.first { $0.id == selectedTakeID } }
    public init() {}
    public mutating func add(_ take: Take) { takes.append(take); selectedTakeID = take.id }
    public mutating func delete(_ id: UUID) {
        takes.removeAll { $0.id == id }
        if selectedTakeID == id { selectedTakeID = takes.last?.id }
    }
}

public struct ProjectManifest: Codable, Equatable, Sendable {
    public var version = 3
    public var id = UUID()
    public var title: String
    public var sourcePDF = "source.pdf"
    public var matchLoudness: Bool?
    public var pages: [PageRecord]
    public init(title: String, pageCount: Int) {
        self.title = title; pages = Array(repeating: PageRecord(), count: pageCount)
    }
    public var selectedTakes: [(page: Int, take: Take)] {
        pages.enumerated().compactMap { index, page in page.selectedTake.map { (index, $0) } }
    }
    public var exportTakes: [(page: Int, take: Take)] {
        selectedTakes.filter { pages[$0.page].includedInExport != false }
    }
}

public enum RecorderError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Audio samples are the recording clock: paused buffers are not written or counted.
public struct SampleClock: Sendable {
    public private(set) var frames: Int64 = 0
    public let sampleRate: Double
    public var duration: Double { Double(frames) / sampleRate }
    public init(sampleRate: Double) { self.sampleRate = sampleRate }
    public mutating func append(frames: Int, paused: Bool) { if !paused { self.frames += Int64(frames) } }
}
