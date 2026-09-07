import Foundation

public enum PageFilter: String, CaseIterable, Identifiable {
    case all = "All pages", unfinished = "Unrecorded", bookmarks = "Bookmarks", recorded = "Recorded"
    public var id: String { rawValue }
}

public enum PresentationTools {
    public static func title(for page: PageRecord, index: Int) -> String {
        let title = (page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Page \(index + 1)" : title
    }
    public static func matchingPages(in manifest: ProjectManifest, query: String, filter: PageFilter, pageText: [String]) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return manifest.pages.indices.filter { index in
            let page = manifest.pages[index]
            switch filter {
            case .all: break
            case .unfinished: if page.selectedTake != nil { return false }
            case .bookmarks: if page.bookmarked != true { return false }
            case .recorded: if page.selectedTake == nil { return false }
            }
            guard !query.isEmpty else { return true }
            let text = ["\(index + 1)", title(for: page, index: index), page.notes ?? "", pageText.indices.contains(index) ? pageText[index] : ""].joined(separator: "\n")
            return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    public static func nextUnrecorded(in manifest: ProjectManifest, after index: Int) -> Int? {
        let order = Array(manifest.pages.indices.dropFirst(index + 1)) + Array(manifest.pages.indices.prefix(index + 1))
        return order.first { manifest.pages[$0].selectedTake == nil }
    }
    /// Markdown export is explicit: presenter notes never enter rendered videos or audio.
    public static func notesMarkdown(_ manifest: ProjectManifest) -> String {
        var result = "# \(manifest.title.replacingOccurrences(of: "\n", with: " "))\n\n"
        for (index, page) in manifest.pages.enumerated() {
            result += "## \(index + 1). \(title(for: page, index: index).replacingOccurrences(of: "\n", with: " "))\n\n"
            if let seconds = page.targetSeconds, seconds > 0 { result += "Target: \(Int(seconds)) seconds\n\n" }
            let notes = (page.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            result += (notes.isEmpty ? "_No presenter notes._" : notes) + "\n\n"
        }
        return result
    }
    public static func clampedPlaybackPosition(_ time: Double, skipping offset: Double, duration: Double) -> Double {
        max(0, min(duration, time + offset))
    }
}

public enum RecordingCountdown {
    /// Cancellation must finish before the caller can start any capture device.
    public static func run(seconds: Int, tick: (Int) async -> Void) async throws {
        guard seconds >= 0, seconds <= 10 else { throw RecorderError.message("Invalid recording countdown.") }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            try Task.checkCancellation()
            await tick(remaining)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try Task.checkCancellation()
    }
}
