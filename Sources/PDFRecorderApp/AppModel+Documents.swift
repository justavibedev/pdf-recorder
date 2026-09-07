import SwiftUI
import PDFKit
import PDFRecorderCore

extension AppModel {
    var pdfDocuments: [ProjectPDFDocument] { manifest?.pdfDocuments ?? [] }
    var currentDocument: ProjectPDFDocument? { manifest?.document(containing: pageIndex) }
    var currentDocumentID: UUID? { currentDocument?.id }
    var currentDocumentPages: Range<Int> {
        guard let id = currentDocumentID else { return 0..<0 }
        return manifest?.pageRange(for: id) ?? 0..<0
    }
    var currentDocumentPageNumber: Int { pageIndex - currentDocumentPages.lowerBound + 1 }
    var currentDocumentRecordedCount: Int {
        guard let manifest else { return 0 }
        return currentDocumentPages.filter { manifest.pages[$0].selectedTake != nil }.count
    }
    func pdfPage(at index: Int) -> PDFPage? {
        guard let source = manifest?.document(containing: index),
              let range = manifest?.pageRange(for: source.id) else { return pdf?.page(at: index) }
        if let document = loadedPDFDocuments[source.id] { return document.page(at: index - range.lowerBound) }
        guard loadedPDFDocuments.isEmpty, pdfDocuments.count == 1 else { return nil }
        return pdf?.page(at: index - range.lowerBound)
    }
    func rememberDocumentPosition() {
        guard let id = currentDocumentID else { return }
        documentWorkspaces[id] = DocumentWorkspace(page: currentDocumentPageNumber - 1, viewport: scene.viewport)
    }
    func selectDocument(_ id: UUID) {
        guard canNavigate, id != currentDocumentID, let range = manifest?.pageRange(for: id), !range.isEmpty else { return }
        rememberDocumentPosition()
        let position = documentWorkspaces[id] ?? DocumentWorkspace()
        navigate(to: range.lowerBound + min(max(0, position.page), range.count - 1))
        scene.viewport = position.viewport
        rememberWorkspace()
    }
    func navigatePage(_ step: Int) {
        let next = pageIndex + step
        guard currentDocumentPages.contains(next) else { return }
        navigate(to: next)
    }
    func cycleDocument(_ step: Int) {
        guard canNavigate, let index = pdfDocuments.firstIndex(where: { $0.id == currentDocumentID }), !pdfDocuments.isEmpty else { return }
        let next = (index + step + pdfDocuments.count) % pdfDocuments.count
        selectDocument(pdfDocuments[next].id)
    }
    func addPDFPanel() {
        guard mode == .idle else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false; panel.message = "Add PDFs to this project. Each document keeps its own pages and takes."
        if panel.runModal() == .OK { openURLs(panel.urls) }
    }
    /// Drop and multi-select use the same ordered, atomic import path.
    func openURLs(_ urls: [URL]) {
        guard mode == .idle, !urls.isEmpty else { return }
        if urls.count == 1, urls[0].pathExtension.lowercased() == "pdfrecorder" { open(urls[0]); return }
        guard urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) else {
            errorMessage = "Choose PDFs together, or open one saved project on its own."; return
        }
        if manifest != nil { addPDFs(urls); return }
        guard flushMetadata() else { return }
        var createdRoot: URL?
        do {
            let imports = try prepareImports(urls)
            guard let first = imports.first else { return }
            let root = recoveryRoot.appendingPathComponent("\(first.title)-\(UUID().uuidString.prefix(8)).pdfrecorder")
            var created = try ProjectStore.create(at: root, source: first.source, title: first.title, pageCount: first.pageCount)
            createdRoot = root
            if imports.count > 1 { created = try ProjectStore.addPDFs(Array(imports.dropFirst()), manifest: created, at: root) }
            let passwords = Dictionary(uniqueKeysWithValues: zip(created.pdfDocuments, imports).compactMap { document, item in
                item.password.map { (document.id, $0) }
            })
            let documents = try loadPDFDocuments(created, at: root, passwords: passwords, askForPasswords: false)
            installProject(created, at: root, documents: documents.0, passwords: documents.1)
            createdRoot = nil
            status = "\(created.pdfDocuments.count) PDF\(created.pdfDocuments.count == 1 ? "" : "s") ready · originals preserved"
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
        if let createdRoot { try? FileManager.default.removeItem(at: createdRoot) }
    }
    func addPDFs(_ urls: [URL]) {
        guard mode == .idle, flushMetadata(), let original = manifest, let root = projectURL, !urls.isEmpty else { return }
        do {
            let imports = try prepareImports(urls)
            guard !imports.isEmpty else { return }
            rememberWorkspace(); stopPlayback()
            let updated = try ProjectStore.addPDFs(imports, manifest: original, at: root)
            // Copy-before-commit is handled by ProjectStore. Resolve copied documents rather than
            // retaining references to files the user may later move or modify outside the project.
            let added = Array(updated.pdfDocuments.dropFirst(original.pdfDocuments.count))
            for (source, item) in zip(added, imports) {
                if let value = item.password { documentPasswords[source.id] = value }
            }
            manifest = updated
            do {
                let loaded = try loadPDFDocuments(updated, at: root, passwords: documentPasswords, askForPasswords: false)
                loadedPDFDocuments = loaded.0; documentPasswords = loaded.1
            } catch {
                errorMessage = "The PDFs were saved, but their preview could not be loaded. Reopen the project. \(error.localizedDescription)"
                return
            }
            searchTask?.cancel(); indexedPageText = []; loadOCRCaches(); refreshPageMatches()
            if let first = added.first { selectDocument(first.id) }
            scheduleSearch(); rememberWorkspace()
            status = "Added \(added.count) PDF\(added.count == 1 ? "" : "s") · switch documents above the viewer"
        } catch is CancellationError { }
        catch { errorMessage = "Could not add PDFs: \(error.localizedDescription)" }
    }
    private func prepareImports(_ urls: [URL]) throws -> [PDFImport] {
        var seen = Set<URL>()
        return try urls.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath()).inserted }.map { url in
            guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else {
                throw RecorderError.message("\(url.lastPathComponent) is not a readable PDF.")
            }
            let password = unlock(document)
            guard !document.isLocked else { throw CancellationError() }
            guard document.pageCount > 0 else { throw RecorderError.message("\(url.lastPathComponent) has no pages.") }
            return PDFImport(source: url, title: url.deletingPathExtension().lastPathComponent, pageCount: document.pageCount, password: password)
        }
    }
    func loadPDFDocuments(_ manifest: ProjectManifest, at root: URL, passwords: [UUID: String] = [:],
                          askForPasswords: Bool = true) throws -> ([UUID: PDFDocument], [UUID: String]) {
        var loaded: [UUID: PDFDocument] = [:], passwords = passwords
        for source in manifest.pdfDocuments {
            guard let document = PDFDocument(url: try ProjectStore.location(source.path, in: root)) else {
                throw RecorderError.message("The PDF ‘\(source.title)’ is missing or corrupt.")
            }
            if document.isLocked, let password = passwords[source.id] { _ = document.unlock(withPassword: password) }
            if document.isLocked, askForPasswords { passwords[source.id] = unlock(document) }
            guard !document.isLocked else { throw CancellationError() }
            guard document.pageCount == source.pageCount else {
                throw RecorderError.message("The page count of ‘\(source.title)’ does not match this project.")
            }
            loaded[source.id] = document
        }
        return (loaded, passwords)
    }
    func installProject(_ value: ProjectManifest, at root: URL, documents: [UUID: PDFDocument], passwords: [UUID: String]) {
        rememberWorkspace(); stopPlayback(); reviewTask?.cancel(); reviewGeneration = UUID()
        searchTask?.cancel(); ocrGeneration = UUID(); ocrTask?.cancel(); ocrTask = nil; ocrProgress = nil
        indexedPageText = []; searchQuery = ""; pageFilter = .all; isSearching = false
        loadedPDFDocuments = documents; documentPasswords = passwords
        let restored = recentProjects.first { $0.id == value.id }?.workspace ?? ProjectWorkspace()
        documentWorkspaces = Dictionary(uniqueKeysWithValues: (restored.documents ?? [:]).compactMap { key, position in
            UUID(uuidString: key).map { ($0, position) }
        })
        pageIndex = max(0, min(value.pages.count - 1, restored.page))
        projectURL = root; manifest = value
        pdf = currentDocumentID.flatMap { documents[$0] }; password = currentDocumentID.flatMap { passwords[$0] }
        thumbnailCache.removeAllObjects(); artworkCache.removeAllObjects(); waveformCache.removeAllObjects()
        showRecovery = false; status = ""; loadOCRCaches()
        loadPage(pageIndex); scene.viewport = restored.viewport
        rememberWorkspace(); loadRehearsalHistory()
    }
    func ocrCacheDirectory(for source: ProjectPDFDocument, at root: URL) -> URL {
        // Preserve the original single-PDF OCR cache when a project is upgraded.
        source.path == manifest?.sourcePDF ? root.appendingPathComponent("reading") : root.appendingPathComponent("reading/\(source.id.uuidString)")
    }
    func loadOCRCaches() {
        guard let root = projectURL else { ocrPages = [:]; return }
        var pages: [Int: PageReadingContent] = [:]
        for source in pdfDocuments {
            guard let range = manifest?.pageRange(for: source.id),
                  let url = try? ProjectStore.location(source.path, in: root),
                  let cached = try? OCRReading.loadCache(pdfURL: url, cacheDirectory: ocrCacheDirectory(for: source, at: root)) else { continue }
            for (index, content) in cached where (0..<source.pageCount).contains(index) { pages[range.lowerBound + index] = content }
        }
        ocrPages = pages
    }
}
