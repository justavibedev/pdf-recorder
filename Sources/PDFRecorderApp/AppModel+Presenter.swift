import AppKit
import UniformTypeIdentifiers
import PDFRecorderCore

@MainActor extension AppModel {
    func showAudienceDisplay() {
        guard artwork != nil else { return }
        showNotes = true; hideInspector = false
        presenterDisplay.show()
    }
    func togglePrompter() {
        presenterDisplay.prompter.toggle()
        showNotes = true; hideInspector = false
    }
    func loadRehearsalHistory() {
        rehearsalSession = nil; rehearsalHistory = []
        guard let projectURL else { return }
        do { rehearsalHistory = try RehearsalStore.load(at: projectURL) }
        catch { errorMessage = error.localizedDescription }
    }
    func beginRehearsal() {
        guard let manifest else { return }
        rehearsalSession = RehearsalSession(manifest: manifest, page: pageIndex, now: ProcessInfo.processInfo.systemUptime)
    }
    func rehearsalVisitPage(_ index: Int) {
        rehearsalSession?.visit(page: index, now: ProcessInfo.processInfo.systemUptime)
    }
    func finishRehearsal() {
        guard var session = rehearsalSession else { return }
        rehearsalSession = nil
        let report = session.finish(now: ProcessInfo.processInfo.systemUptime)
        rehearsalHistory.insert(report, at: 0)
        showRehearsalHistory = true
        guard let projectURL else { return }
        do { try RehearsalStore.save(rehearsalHistory, at: projectURL) }
        catch { errorMessage = "The rehearsal report is available for export but could not be saved in this project: \(error.localizedDescription)" }
    }
    func exportRehearsal(_ report: RehearsalReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = report.title + " — Rehearsal.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.markdown.write(to: url, atomically: true, encoding: .utf8); status = "Rehearsal report exported" }
        catch { errorMessage = error.localizedDescription }
    }
}
