import Foundation

/// Streams a JSON event array in 64 KB blocks, retaining only the current event while exporting.
/// Strings and nested objects are parsed structurally before each event is decoded and validated.
public final class EventLogReader {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var offset = 0
    private var started = false
    private var needsSeparator = false
    private var ended = false
    private var lastTime = -Double.infinity
    public init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }

    private func byte() throws -> UInt8? {
        if offset == buffer.count {
            try Task.checkCancellation()
            buffer = Array(try handle.read(upToCount: 65_536) ?? Data()); offset = 0
            if buffer.isEmpty { return nil }
        }
        defer { offset += 1 }
        return buffer[offset]
    }
    private func significant() throws -> UInt8? {
        while let value = try byte() { if ![9, 10, 13, 32].contains(value) { return value } }
        return nil
    }
    public func next() throws -> TimedEvent? {
        if ended { return nil }
        if !started {
            guard try significant() == 91 else { throw RecorderError.message("The interaction log must be a JSON array.") }
            started = true
        }
        var first = try significant()
        if needsSeparator {
            if first == 93 { return try finish() }
            guard first == 44 else { throw RecorderError.message("The interaction log is incomplete or invalid.") }
            first = try significant()
        } else if first == 93 { return try finish() }
        guard first == 123 else { throw RecorderError.message("An interaction event is incomplete or invalid.") }
        var data = Data([123])
        var depth = 1, inString = false, escaped = false
        while depth > 0 {
            guard let value = try byte() else { throw RecorderError.message("The interaction log was interrupted inside an event.") }
            data.append(value)
            if inString {
                if escaped { escaped = false }
                else if value == 92 { escaped = true }
                else if value == 34 { inString = false }
            } else {
                if value == 34 { inString = true }
                else if value == 123 || value == 91 { depth += 1 }
                else if value == 125 || value == 93 { depth -= 1 }
            }
        }
        let event = try JSONDecoder().decode(TimedEvent.self, from: data)
        try ProjectStore.validate([event])
        guard event.time >= lastTime else { throw RecorderError.message("The interaction log is out of order.") }
        lastTime = event.time; needsSeparator = true
        return event
    }
    private func finish() throws -> TimedEvent? {
        guard try significant() == nil else { throw RecorderError.message("The interaction log contains trailing data.") }
        ended = true
        return nil
    }
    public static func readAll(url: URL) throws -> [TimedEvent] {
        let reader = try EventLogReader(url: url)
        var events: [TimedEvent] = []
        while let event = try reader.next() { events.append(event) }
        return events
    }
}

/// Sequential renderer used by export; trim-start state is reconstructed from preceding events.
final class ExportTimeline {
    private let reader: EventLogReader?
    private let events: [TimedEvent]
    private var index = 0
    private var pending: TimedEvent?
    private var scene: Scene
    init(item: ExportItem) throws {
        reader = try item.eventsURL.map { try EventLogReader(url: $0) }
        events = item.events
        scene = Scene(viewport: item.take.initialViewport)
        pending = try reader?.next() ?? (reader == nil ? events.first : nil)
    }
    func seek(to time: Double) throws -> Scene {
        while let event = pending, event.time <= time {
            scene.apply(event.action)
            if let reader { pending = try reader.next() }
            else { index += 1; pending = index < events.count ? events[index] : nil }
        }
        return scene
    }
}
