import Foundation
import PDFKit

/// Import credentials exist only for this operation and are never encoded in a project.
public struct PDFImport: Sendable {
    public var source: URL
    public var title: String
    public var pageCount: Int
    public var password: String?
    public init(source: URL, title: String, pageCount: Int, password: String? = nil) {
        self.source = source; self.title = title; self.pageCount = pageCount; self.password = password
    }
}

extension ProjectStore {
    /// Copies all inputs before publishing any new document metadata. Existing page
    /// indexes, recording paths, selected takes, and source PDF bytes stay stable.
    public static func addPDFs(_ imports: [PDFImport], manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        guard !imports.isEmpty else { return manifest }
        try validateDocuments(manifest, at: root, checkingFiles: false)
        var total = manifest.pages.count
        for input in imports {
            guard input.pageCount > 0, input.pageCount <= 100_000 - total else {
                throw RecorderError.message("A project can contain at most 100,000 PDF pages, and each PDF must contain a page.")
            }
            total += input.pageCount
        }
        let manager = FileManager.default
        let staging = try location(".pdf-import-\(UUID().uuidString)", in: root)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var updated = manifest
        updated.version = 4
        updated.documents = manifest.pdfDocuments
        var additions: [(staged: URL, destination: URL)] = []
        // Validate the copied snapshot, including its password, rather than an input
        // that another application could replace between validation and copying.
        for input in imports {
            let id = UUID()
            let folder = staging.appendingPathComponent(id.uuidString, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            let source = folder.appendingPathComponent("source.pdf")
            try manager.copyItem(at: input.source, to: source)
            try validatePDF(at: source, title: input.title, pageCount: input.pageCount, password: input.password, requireUnlocked: true)
            let path = "documents/\(id.uuidString)/source.pdf"
            let target = try location(path, in: root).deletingLastPathComponent()
            guard !manager.fileExists(atPath: target.path) else { throw RecorderError.message("An imported PDF already exists at this location.") }
            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.documents?.append(.init(id: id, title: title.isEmpty ? input.source.deletingPathExtension().lastPathComponent : title,
                                             path: path, pageCount: input.pageCount))
            updated.pages.append(contentsOf: repeatElement(PageRecord(), count: input.pageCount))
            additions.append((folder, target))
        }
        try validateDocuments(updated, at: root, checkingFiles: false)
        let documentsDirectory = try location("documents", in: root)
        let directoryAlreadyExisted = manager.fileExists(atPath: documentsDirectory.path)
        var moved: [URL] = []
        do {
            if directoryAlreadyExisted {
                guard try documentsDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw RecorderError.message("The project's documents path is not a folder.")
                }
            } else { try manager.createDirectory(at: documentsDirectory, withIntermediateDirectories: false) }
            for addition in additions {
                try manager.moveItem(at: addition.staged, to: addition.destination)
                moved.append(addition.destination)
            }
            // Atomic manifest replacement is the commit point. A crash before this
            // leaves only unreferenced PDF folders; the previous project still opens.
            try save(updated, at: root)
            return updated
        } catch {
            for url in moved { try? manager.removeItem(at: url) }
            if !directoryAlreadyExisted { try? manager.removeItem(at: documentsDirectory) }
            throw error
        }
    }

    static func validateDocuments(_ manifest: ProjectManifest, at root: URL, checkingFiles: Bool = true) throws {
        guard (1...4).contains(manifest.version) else { throw RecorderError.message("This project uses an unsupported format version (\(manifest.version)).") }
        guard !manifest.pages.isEmpty, manifest.pages.count <= 100_000, manifest.sourcePDF == "source.pdf" else {
            throw RecorderError.message("The project has an invalid page list or source path.")
        }
        let documents = manifest.pdfDocuments
        guard !documents.isEmpty, documents.count <= manifest.pages.count else { throw RecorderError.message("The project has an invalid PDF list.") }
        var ids = Set<UUID>(), paths = Set<String>(), count = 0
        for (index, document) in documents.enumerated() {
            let expectedPath = index == 0 ? manifest.sourcePDF : "documents/\(document.id.uuidString)/source.pdf"
            guard document.pageCount > 0, document.pageCount <= manifest.pages.count - count,
                  ids.insert(document.id).inserted, paths.insert(document.path).inserted,
                  document.path == expectedPath, index != 0 || document.id == manifest.id else {
                throw RecorderError.message("A source PDF has an invalid path, identifier, or page count.")
            }
            count += document.pageCount
            let url = try location(document.path, in: root)
            if checkingFiles {
                try validatePDF(at: url, title: document.title, pageCount: document.pageCount, password: nil, requireUnlocked: false)
            }
        }
        guard count == manifest.pages.count else { throw RecorderError.message("The PDF page counts do not match the project page list.") }
    }

    private static func validatePDF(at url: URL, title: String, pageCount: Int, password: String?, requireUnlocked: Bool) throws {
        try autoreleasepool {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let pdf = PDFDocument(url: url) else {
                throw RecorderError.message("The PDF ‘\(title)’ is missing or could not be opened.")
            }
            if pdf.isLocked {
                if !requireUnlocked { return } // Opening the app requests credentials without storing them.
                guard pdf.unlock(withPassword: password ?? "") else { throw RecorderError.message("Unlock the PDF ‘\(title)’ before adding it.") }
            }
            guard pdf.pageCount == pageCount else { throw RecorderError.message("The page count of ‘\(title)’ changed. Open the PDF again before adding it.") }
        }
    }
}
