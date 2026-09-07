import Foundation

public enum BatchExport {
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
