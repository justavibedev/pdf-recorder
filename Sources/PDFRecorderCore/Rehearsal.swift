import Foundation

public struct RehearsalPageTiming: Codable, Equatable, Identifiable, Sendable {
    public var page: Int
    public var title: String
    public var targetSeconds: Double?
    public var actualSeconds: Double
    public var visits: Int
    public var id: Int { page }
    public var overrun: Double { max(0, actualSeconds - (targetSeconds ?? actualSeconds)) }
}

public struct RehearsalReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var title: String
    public var pages: [RehearsalPageTiming]
    public var totalSeconds: Double { pages.reduce(0) { $0 + $1.actualSeconds } }
    public var plannedSeconds: Double { pages.reduce(0) { $0 + ($1.targetSeconds ?? 0) } }
    public var visitedPages: Int { pages.filter { $0.visits > 0 }.count }
    public var totalOverrun: Double { pages.reduce(0) { $0 + $1.overrun } }

    public var markdown: String {
        func timestamp(_ seconds: Double) -> String {
            let value = Int(seconds.rounded())
            return String(format: "%d:%02d", value / 60, value % 60)
        }
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var text = "# \(title) — Rehearsal\n\n\(startedAt.formatted(date: .abbreviated, time: .shortened))\n\n"
        text += "Actual: \(timestamp(totalSeconds)) · Planned: \(timestamp(plannedSeconds)) · Visited: \(visitedPages)/\(pages.count) pages\n\n"
        text += "| Page | Title | Planned | Actual | Over target | Visits |\n| --- | --- | --- | --- | --- | --- |\n"
        for page in pages {
            text += "| \(page.page + 1) | \(cell(page.title)) | \(page.targetSeconds.map(timestamp) ?? "—") | \(page.visits > 0 ? timestamp(page.actualSeconds) : "Not visited") | \(page.overrun > 0 ? timestamp(page.overrun) : "—") | \(page.visits) |\n"
        }
        return text + "\nRepeated visits are added to the same page. This report contains timing only; no microphone recording was made.\n"
    }
}

/// Receives a monotonic clock from the caller so wall-clock changes cannot alter elapsed time.
/// Revisiting a page adds time to it instead of replacing the earlier visit.
public struct RehearsalSession: Sendable {
    public private(set) var report: RehearsalReport
    public private(set) var currentPage: Int
    private var visitStarted: Double
    private var finished = false

    public init(manifest: ProjectManifest, page: Int, now: Double, date: Date = Date()) {
        let pages = manifest.pages.enumerated().map { index, page in
            RehearsalPageTiming(page: index, title: PresentationTools.title(for: page, index: index),
                                targetSeconds: page.targetSeconds.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }, actualSeconds: 0, visits: 0)
        }
        report = RehearsalReport(id: UUID(), startedAt: date, finishedAt: date, title: manifest.title, pages: pages)
        currentPage = page; visitStarted = now
        if report.pages.indices.contains(page) { report.pages[page].visits = 1 }
    }
    public mutating func visit(page: Int, now: Double) {
        guard !finished, report.pages.indices.contains(page), page != currentPage else { return }
        addElapsed(now: now)
        currentPage = page; report.pages[page].visits += 1
    }
    public mutating func finish(now: Double, date: Date = Date()) -> RehearsalReport {
        if !finished { addElapsed(now: now); report.finishedAt = date; finished = true }
        return report
    }
    private mutating func addElapsed(now: Double) {
        guard now.isFinite, visitStarted.isFinite else { return }
        if report.pages.indices.contains(currentPage) { report.pages[currentPage].actualSeconds += max(0, now - visitStarted) }
        visitStarted = max(visitStarted, now)
    }
}

public enum RehearsalStore {
    private struct History: Codable { var version = 1; var reports: [RehearsalReport] }
    public static func load(at root: URL) throws -> [RehearsalReport] {
        let url = root.appendingPathComponent("rehearsals.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
        guard history.version == 1, Set(history.reports.map(\.id)).count == history.reports.count,
              history.reports.allSatisfy({ report in
                  Set(report.pages.map(\.page)).count == report.pages.count && report.pages.allSatisfy { page in
                      page.page >= 0 && page.visits >= 0 && page.actualSeconds.isFinite && page.actualSeconds >= 0 &&
                      (page.targetSeconds.map { $0.isFinite && $0 > 0 && $0 <= 86_400 } ?? true)
                  }
              }) else { throw RecorderError.message("The rehearsal history is damaged. Its file has been kept; the rest of the project can still be used.") }
        return history.reports
    }
    public static func save(_ reports: [RehearsalReport], at root: URL) throws {
        // Do not replace an unreadable history with a new, apparently empty session history.
        // The caller can still export an unsaved report while the original file stays recoverable.
        _ = try load(at: root)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(History(reports: reports)).write(to: root.appendingPathComponent("rehearsals.json"), options: .atomic)
    }
}

/// A small, deterministic scrolling clock. Inactive updates reset the anchor so a pause never causes a jump.
public struct PrompterClock {
    public private(set) var offset = 0.0
    private var lastTime: Double?
    public init() {}
    public mutating func update(now: Double, running: Bool, speed: Double, maximum: Double) -> Double {
        defer { lastTime = now }
        guard now.isFinite, let previous = lastTime, running else { return offset }
        offset = max(0, min(max(0, maximum), offset + max(0, now - previous) * max(0, speed)))
        return offset
    }
    public mutating func scroll(to value: Double) { offset = max(0, value); lastTime = nil }
}
