import Foundation

public struct RecorderPreferences: Codable, Equatable, Sendable {
    public var microphoneID = ""
    public var countdown = 3
    public var playbackRate: Float = 1
    public var notesFontSize = 17.0
    public var hidePages = false
    public var hideInspector = false
    public var showNotes = false
    /// Optional so preferences from earlier releases keep decoding.
    public var advancedUI: Bool?
    public var largeControls = false
    public init() {}
}

public struct DocumentWorkspace: Codable, Equatable, Sendable {
    public var page: Int
    public var viewport: Viewport
    public init(page: Int = 0, viewport: Viewport = Viewport()) { self.page = page; self.viewport = viewport }
}

public struct ProjectWorkspace: Codable, Equatable, Sendable {
    public var page = 0
    public var viewport = Viewport()
    public var documents: [String: DocumentWorkspace]?
    public init(page: Int = 0, viewport: Viewport = Viewport(), documents: [String: DocumentWorkspace]? = nil) {
        self.page = page; self.viewport = viewport; self.documents = documents
    }
}

public struct RecentProject: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var title: String
    public var pageCount: Int
    public var recordedCount: Int
    public var lastOpened: Date
    public var pinned: Bool
    public var workspace: ProjectWorkspace
    public var previewName: String?
    public init(manifest: ProjectManifest, url: URL, workspace: ProjectWorkspace = .init()) {
        id = manifest.id; path = url.path; title = manifest.title; pageCount = manifest.pages.count
        recordedCount = manifest.selectedTakes.count; lastOpened = Date(); pinned = false; self.workspace = workspace
    }
}

public enum WorkspaceStore {
    public static func loadPreferences(at root: URL) throws -> RecorderPreferences {
        let url = root.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try ProjectStore.decode(RecorderPreferences.self, from: url)
    }
    public static func savePreferences(_ value: RecorderPreferences, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ProjectStore.write(value, to: root.appendingPathComponent("preferences.json"))
    }
    public static func loadRecent(at root: URL) throws -> [RecentProject] {
        let url = root.appendingPathComponent("recent-projects.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return sorted(try ProjectStore.decode([RecentProject].self, from: url))
    }
    public static func saveRecent(_ projects: [RecentProject], at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep every pinned project and the 30 most recently opened unpinned projects.
        let ordered = sorted(projects)
        try ProjectStore.write(ordered.filter(\.pinned) + Array(ordered.filter { !$0.pinned }.prefix(30)), to: root.appendingPathComponent("recent-projects.json"))
    }
    public static func sorted(_ values: [RecentProject]) -> [RecentProject] {
        values.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.lastOpened > $1.lastOpened }
    }
}

public enum ExportPageSelection {
    /// User page numbers are one-based; results are unique and remain in PDF order.
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        var result = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count <= 2, let first = Int(ends[0]), first > 0, first <= pageCount else {
                throw RecorderError.message("Enter page numbers such as 1, 3-5 within this PDF.")
            }
            let last = ends.count == 2 ? Int(ends[1]) : first
            guard let last, last >= first, last <= pageCount else { throw RecorderError.message("That page range is outside this PDF or reversed.") }
            result.formUnion((first...last).map { $0 - 1 })
        }
        guard !result.isEmpty else { throw RecorderError.message("Choose at least one page.") }
        return result.sorted()
    }
}
