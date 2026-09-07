import Foundation

public enum BatchExport {
    /// Imported project titles are display text, never filesystem paths.
    public static func destination(in parent: URL, title: String) -> URL {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = title.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // Bound UTF-8 bytes as well as visual length for emoji and combined characters.
        var name = ""
        for character in cleaned {
            guard name.utf8.count + String(character).utf8.count <= 160 else { break }
            name.append(character)
        }
        if name.isEmpty { name = "Presentation" }
        return parent.appendingPathComponent("\(name) — Pages \(UUID().uuidString.prefix(6))", isDirectory: true)
    }

    public static func run(pages: [Int], destination: URL, fileExtension: String,
                           exportPage: @Sendable (Int, URL) async throws -> Void) async throws {
        guard !pages.isEmpty, !FileManager.default.fileExists(atPath: destination.path),
              ["mp4", "m4a"].contains(fileExtension), pages.allSatisfy({ $0 >= 0 }) else { throw RecorderError.message("Choose a new folder for this batch export.") }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".pdfrecorder-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        for page in pages {
            try Task.checkCancellation()
            let output = staged.appendingPathComponent(String(format: "Page %03d.%@", page + 1, fileExtension))
            try await exportPage(page, output)
            guard FileManager.default.fileExists(atPath: output.path) else { throw RecorderError.message("A page export did not create its output.") }
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staged, to: destination)
    }
}
