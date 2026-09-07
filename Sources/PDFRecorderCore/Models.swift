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

public enum InkTool: String, Codable, CaseIterable, Sendable { case pointer, pen, highlighter, eraser, pan }

public struct Stroke: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tool: InkTool
    public var color: String
    public var width: Double
    public var points: [Point]
    public init(id: UUID = UUID(), tool: InkTool, color: String, width: Double, points: [Point]) {
        self.id = id; self.tool = tool; self.color = color; self.width = width; self.points = points
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

/// Advances incrementally during playback/export; seeks backwards rebuild from the start.
public struct Timeline {
    public let events: [TimedEvent]
    public private(set) var scene: Scene
    private var index = 0
    private var previousTime = -Double.infinity
    private let initialViewport: Viewport
    public init(events: [TimedEvent], initialViewport: Viewport) {
        self.events = events; self.initialViewport = initialViewport
        scene = Scene(viewport: initialViewport)
    }
    public mutating func seek(to time: Double) -> Scene {
        if time < previousTime { index = 0; scene = Scene(viewport: initialViewport) }
        while index < events.count && events[index].time <= time {
            scene.apply(events[index].action); index += 1
        }
        previousTime = time
        return scene
    }
}

public struct Take: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var duration: Double
    public var initialViewport: Viewport
    public var audioPath: String
    public var eventsPath: String
    public var recovered: Bool
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
    public var version = 2
    public var id = UUID()
    public var title: String
    public var sourcePDF = "source.pdf"
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
