import SwiftUI
import PDFRecorderCore

@main @MainActor struct PDFRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some SwiftUI.Scene {
        Window("PDF Recorder", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear { delegate.model = model; NSApp.appearance = NSAppearance(named: .darkAqua) }
                .onOpenURL { model.openURLs([$0]) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDFs or Project…", action: model.openPanel).keyboardShortcut("o").disabled(model.mode != .idle)
                Button("Add PDFs…", action: model.addPDFPanel).keyboardShortcut("o", modifiers: [.command, .option]).disabled(model.mode != .idle)
                Button("Project Library", action: model.showLibrary).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.mode != .idle)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project As…", action: model.saveAs).keyboardShortcut("s").disabled(model.manifest == nil || model.mode != .idle)
                Button("Show Project in Finder", action: model.revealProject).disabled(model.manifest == nil)
                Button("Storage & Recovery…", action: model.refreshStorage).disabled(model.manifest == nil || model.mode != .idle)
            }
            CommandMenu("Workspace") {
                Button("Search Commands…") { model.showCommands = true }.keyboardShortcut("k")
                Button("Find in PDF and Notes") { model.focusSearchToken += 1 }.keyboardShortcut("f").disabled(model.manifest == nil)
                Button("Show / Hide Pages") { model.focusMode.toggle() }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Show / Hide Inspector") { model.hideInspector.toggle() }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Previous Document") { model.cycleDocument(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(!model.canNavigate || model.pdfDocuments.count < 2)
                Button("Next Document") { model.cycleDocument(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!model.canNavigate || model.pdfDocuments.count < 2)
                Toggle("Larger Controls", isOn: $model.largeControls)
                Divider()
                Button("Recognize Scanned Text", action: model.startOCR).disabled(model.manifest == nil || model.mode != .idle || model.ocrTask != nil)
                Button("Clear Marks", action: model.clearMarks).disabled(!model.canDraw || model.scene.strokes.isEmpty)
                if let deleted = model.lastDeletedTake { Button("Undo Delete Take") { model.restoreDeletedTake(deleted) }.disabled(model.mode != .idle) }
            }
            CommandMenu("Recording") {
                Button("Record New Take", action: model.record).keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.mode != .idle || model.manifest == nil)
                Button("Pause / Resume", action: model.togglePause).keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.mode != .recording && model.mode != .paused)
                Button("Stop & Save Take") { Task { await model.stopRecording() } }.keyboardShortcut(".").disabled(model.mode != .recording && model.mode != .paused)
                Divider()
                Button("Play / Pause Take") { model.play() }.keyboardShortcut(.space, modifiers: .command).disabled(model.selectedTake == nil || model.isRecording)
                Button("Stop Playback", action: model.stopPlayback).disabled(model.player == nil && model.mode != .loadingPlayback)
                Button("Previous Page") { model.navigatePage(-1) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(!model.canNavigate || model.pageIndex == model.currentDocumentPages.lowerBound)
                Button("Next Page") { model.navigatePage(1) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(!model.canNavigate || model.pageIndex + 1 >= model.currentDocumentPages.upperBound)
            }
            CommandMenu("Presenting") {
                Button("Audience Display", action: model.showAudienceDisplay).keyboardShortcut("d", modifiers: [.command, .shift]).disabled(model.manifest == nil)
                Button("Hold / Resume Teleprompter", action: model.togglePrompter).keyboardShortcut(.space, modifiers: [.command, .shift]).disabled(model.manifest == nil)
                Button("Rehearsal Reports…") { model.showRehearsalHistory = true }.disabled(model.manifest == nil)
                Divider()
                Button("Practice / End Practice", action: model.togglePractice).keyboardShortcut("r", modifiers: [.command, .option]).disabled(model.manifest == nil || (model.mode != .idle && model.mode != .rehearsing))
                Button("Show Notes / Takes") { model.showNotes.toggle(); model.hideInspector = false }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Bookmark Page", action: model.toggleBookmark).keyboardShortcut("b", modifiers: [.command, .shift]).disabled(model.mode != .idle || model.manifest == nil)
                Button("Next Unrecorded Page", action: model.nextUnrecorded).keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!model.canNavigate)
                Button("Focus Mode") { model.focusMode.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Export Presenter Notes…", action: model.exportNotes).disabled(model.mode != .idle || model.manifest == nil)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.mode == .savingProject { return .terminateCancel }
        guard model.flushMetadata() else { return .terminateCancel }
        model.rememberWorkspace(); model.savePreferences(); model.ocrTask?.cancel()
        if model.mode == .rehearsing { model.finishRehearsal() }
        if model.mode == .checkingMicrophone {
            Task { await model.stopMicrophoneCheck(); sender.reply(toApplicationShouldTerminate: true) }; return .terminateLater
        }
        if model.mode == .countdown { model.cancelCountdown() }
        if model.mode == .starting || model.mode == .stopping { return .terminateCancel }
        if model.mode == .recording || model.mode == .paused {
            Task { await model.stopRecording(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        if model.mode == .exporting { model.cancelExport() }
        return .terminateNow
    }
}
