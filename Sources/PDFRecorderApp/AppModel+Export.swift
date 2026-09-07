import SwiftUI
import PDFRecorderCore
import UniformTypeIdentifiers

enum ExportScope: String, CaseIterable, Identifiable {
    case included = "All documents", document = "Current document", current = "Current page", range = "Page range", chapter = "Current chapter"
    var id: String { rawValue }
}

extension AppModel {
    func requestedExportPages() throws -> [Int] {
        guard let manifest else { return [] }
        switch exportScope {
        case .included: return Array(manifest.pages.indices).filter { manifest.pages[$0].includedInExport != false }
        case .document: return Array(currentDocumentPages).filter { manifest.pages[$0].includedInExport != false }
        case .current: return [pageIndex]
        case .range: return try ExportPageSelection.parse(exportRange, pageCount: currentDocumentPages.count).map { currentDocumentPages.lowerBound + $0 }
        case .chapter:
            let starts = Set(outlineItems.map(\.page)).sorted()
            let first = starts.last { $0 <= pageIndex } ?? currentDocumentPages.lowerBound
            let end = starts.first { $0 > pageIndex } ?? currentDocumentPages.upperBound
            return Array(first..<end)
        }
    }
    func exportSelection() throws -> [(page: Int, take: Take)] {
        guard let manifest else { return [] }
        return try requestedExportPages().compactMap { index in manifest.pages[index].selectedTake.map { (index, $0) } }
    }
    var exportOptions: ExportOptions { .init(preset: exportPreset, matchLoudness: manifest?.matchLoudness == true) }
    var exportSelectedDuration: Double { (try? exportSelection().reduce(0) { $0 + $1.take.playbackDuration }) ?? 0 }
    var exportRemaining: Double? { ExportOptions.estimatedSecondsRemaining(progress: exportProgress, elapsed: Date().timeIntervalSince(exportStartedAt)) }
    func export() {
        guard mode == .idle, flushMetadata(), let manifest, let root = projectURL else { return }
        stopPlayback()
        do {
            let selected = try exportSelection()
            guard !selected.isEmpty else { throw RecorderError.message("There are no selected recordings in these pages.") }
            let kind = exportKind, separate = exportSeparately, options = exportOptions
            let destination: URL
            if separate {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                panel.message = "Choose a folder for a new batch of page recordings. The batch appears only after every page exports successfully."
                guard panel.runModal() == .OK, let parent = panel.url else { return }
                destination = BatchExport.destination(in: parent, title: manifest.title)
            } else {
                let panel = NSSavePanel(); panel.allowedContentTypes = kind == .video ? [.mpeg4Movie] : [.mpeg4Audio]
                panel.nameFieldStringValue = manifest.title + (kind == .video ? ".mp4" : ".m4a")
                guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url
            }
            // File references only; decoding and rendering happen in the background one take at a time.
            let items = try selected.map { item in
                guard let source = manifest.document(containing: item.page), let localPage = manifest.localPageIndex(globalPage: item.page) else {
                    throw RecorderError.message("A selected recording has no source PDF.")
                }
                return ExportItem(page: item.page, take: item.take, eventsURL: try ProjectStore.location(item.take.eventsPath, in: root),
                                  audioURL: try ProjectStore.location(item.take.audioPath, in: root),
                                  pdfURL: try ProjectStore.location(source.path, in: root), pdfPage: localPage, pdfPassword: documentPasswords[source.id])
            }
            let pdfURL = try ProjectStore.location(manifest.sourcePDF, in: root), password = self.password
            mode = .exporting; exportProgress = 0; exportStartedAt = Date()
            exportTask = Task {
                let observer = self
                let worker = Task.detached(priority: .userInitiated) {
                    let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in observer.exportProgress = value } }
                    if separate {
                        try await BatchExport.run(pages: items.map(\.page), destination: destination, fileExtension: kind == .video ? "mp4" : "m4a") { page, url in
                            guard let index = items.firstIndex(where: { $0.page == page }) else { return }
                            let report: @Sendable (Double) -> Void = { progress((Double(index) + $0) / Double(items.count)) }
                            if kind == .video { try await VideoExporter.export(pdfURL: pdfURL, password: password, items: [items[index]], to: url, options: options, progress: report) }
                            else { try await AudioExporter.export(items: [items[index]], to: url, options: options, progress: report) }
                        }
                    } else if kind == .video { try await VideoExporter.export(pdfURL: pdfURL, password: password, items: items, to: destination, options: options, progress: progress) }
                    else { try await AudioExporter.export(items: items, to: destination, options: options, progress: progress) }
                }
                do {
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    status = separate ? "Page recordings exported" : (kind == .video ? "Video exported" : "Audio exported")
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch is CancellationError { status = "Export cancelled" }
                catch { errorMessage = error.localizedDescription }
                mode = .idle; exportTask = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
