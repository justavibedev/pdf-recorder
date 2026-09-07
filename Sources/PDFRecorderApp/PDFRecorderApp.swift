import SwiftUI
import PDFRecorderCore

@main struct PDFRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some SwiftUI.Scene {
        Window("PDF Recorder", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .onOpenURL { model.open($0) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF or Project…", action: model.openPanel).keyboardShortcut("o").disabled(model.mode != .idle)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project As…", action: model.saveAs).keyboardShortcut("s").disabled(model.manifest == nil || model.mode != .idle)
                Button("Show Project in Finder", action: model.revealProject).disabled(model.manifest == nil)
            }
            CommandGroup(replacing: .undoRedo) { Button("Undo Mark", action: model.undo).keyboardShortcut("z").disabled(!model.canDraw) }
            CommandMenu("Recording") {
                Button("Record New Take", action: model.record).keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.mode != .idle || model.manifest == nil)
                Button("Pause / Resume", action: model.togglePause).keyboardShortcut("p", modifiers: [.command, .shift]).disabled(model.mode != .recording && model.mode != .paused)
                Button("Stop & Save Take") { Task { await model.stopRecording() } }.keyboardShortcut(".").disabled(model.mode != .recording && model.mode != .paused)
                Divider()
                Button("Play / Pause Take") { model.play() }.keyboardShortcut(.space, modifiers: .command).disabled(model.selectedTake == nil || model.isRecording)
                Button("Previous Page") { model.navigate(to: model.pageIndex - 1) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(!model.canNavigate)
                Button("Next Page") { model.navigate(to: model.pageIndex + 1) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(!model.canNavigate)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.mode == .starting || model.mode == .stopping { return .terminateCancel }
        if model.mode == .recording || model.mode == .paused {
            Task { await model.stopRecording(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        if model.mode == .exporting { model.cancelExport() }
        return .terminateNow
    }
}
