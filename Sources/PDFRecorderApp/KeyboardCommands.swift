import SwiftUI
import PDFRecorderCore

extension InkTool {
    var commandTitle: String {
        switch self {
        case .selectText: return "Select PDF Text"
        case .pointer: return "Pointer"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        case .pan: return "Pan"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text Label"
        }
    }
    var canvasKey: String {
        switch self {
        case .pointer: return "V"
        case .pen: return "P"
        case .highlighter: return "H"
        case .eraser: return "E"
        case .pan: return "M"
        case .line: return "L"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .text: return "T"
        case .selectText: return "S"
        }
    }
}

@MainActor private struct PaletteCommand: Identifiable {
    let id: String, title: String, category: String, key: String
    let enabled: Bool
    let action: () -> Void
    init(_ id: String, _ title: String, _ category: String, key: String = "", enabled: Bool = true, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.category = category; self.key = key; self.enabled = enabled; self.action = action
    }
}

/// Searchable commands share the same model actions and availability rules as the visible controls.
@MainActor struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool
    private var hasProject: Bool { model.manifest != nil }
    private var idle: Bool { model.mode == .idle }
    private var commands: [PaletteCommand] {
        var values: [PaletteCommand] = [
            .init("open", "Open PDF or Project…", "Projects", key: "⌘O", enabled: idle, action: model.openPanel),
            .init("library", "Recent and Pinned Projects", "Projects", enabled: idle, action: model.showLibrary),
            .init("add-pdfs", "Add PDFs to Project…", "Documents", key: "⌥⌘O", enabled: idle, action: model.addPDFPanel),
            .init("previous-document", "Previous Document", "Documents", key: "⌥⌘←", enabled: model.canNavigate && model.pdfDocuments.count > 1) { model.cycleDocument(-1) },
            .init("next-document", "Next Document", "Documents", key: "⌥⌘→", enabled: model.canNavigate && model.pdfDocuments.count > 1) { model.cycleDocument(1) },
            .init("save", "Save Project As…", "Projects", key: "⌘S", enabled: hasProject && idle, action: model.saveAs),
            .init("storage", "Storage and Recovery Center", "Projects", enabled: hasProject && idle) { model.showStorage = true; model.refreshStorage() },
            .init("reveal", "Show Project in Finder", "Projects", enabled: hasProject, action: model.revealProject),
            .init("search", "Find Text, Notes or Page Titles", "Reading", key: "⌘F", enabled: hasProject) { model.focusMode = false; model.focusSearchToken += 1 },
            .init("ocr", "Recognize Text in Scanned Pages", "Reading", enabled: hasProject && idle && model.ocrProgress == nil, action: model.startOCR),
            .init("bookmark", "Bookmark / Unbookmark Page", "Reading", key: "⇧⌘B", enabled: hasProject && idle, action: model.toggleBookmark),
            .init("unfinished", "Next Unrecorded Page", "Reading", key: "⇧⌘U", enabled: hasProject && model.canNavigate, action: model.nextUnrecorded),
            .init("previous", "Previous Page", "Navigation", key: "Page Up / ←", enabled: model.canNavigate && model.pageIndex > model.currentDocumentPages.lowerBound) { model.navigatePage(-1) },
            .init("next", "Next Page", "Navigation", key: "Page Down / →", enabled: model.canNavigate && model.pageIndex + 1 < model.currentDocumentPages.upperBound) { model.navigatePage(1) },
            .init("first", "First Page", "Navigation", key: "Home", enabled: hasProject && model.canNavigate) { model.navigate(to: model.currentDocumentPages.lowerBound) },
            .init("last", "Last Page", "Navigation", key: "End", enabled: hasProject && model.canNavigate) { model.navigate(to: model.currentDocumentPages.upperBound - 1) },
            .init("zoom-in", "Zoom In", "Canvas", key: "+", enabled: model.canDraw) { model.zoom(1.2) },
            .init("zoom-out", "Zoom Out", "Canvas", key: "−", enabled: model.canDraw) { model.zoom(1 / 1.2) },
            .init("fit", "Fit Page to Canvas", "Canvas", key: "0", enabled: model.canDraw, action: model.fit),
            .init("undo", "Undo Mark", "Annotations", key: "⌘Z in canvas", enabled: model.canDraw && !model.groupedUndoActions.isEmpty, action: model.undo),
            .init("redo", "Redo Mark", "Annotations", key: "⇧⌘Z in canvas", enabled: model.canDraw && !model.redoActions.isEmpty, action: model.redo),
            .init("clear", "Clear All App Marks", "Annotations", enabled: model.canDraw && !model.scene.strokes.isEmpty, action: model.clearMarks),
            .init("record", "Record New Take", "Recording", key: "⇧⌘R", enabled: hasProject && idle, action: model.record),
            .init("pause-recording", "Pause / Resume Recording", "Recording", key: "⇧⌘P", enabled: model.mode == .recording || model.mode == .paused, action: model.togglePause),
            .init("stop-recording", "Stop and Save Take", "Recording", key: "⌘.", enabled: model.mode == .recording || model.mode == .paused) { Task { await model.stopRecording() } },
            .init("cancel-countdown", "Cancel Recording Countdown", "Recording", key: "Esc", enabled: model.mode == .countdown, action: model.cancelCountdown),
            .init("microphone-check", "Check Microphone — Start Audio Input", "Recording", enabled: idle, action: model.startMicrophoneCheck),
            .init("play", "Play / Pause Current Take", "Review", key: "⌘Space", enabled: model.selectedTake != nil && (idle || model.mode == .playing)) { model.play() },
            .init("play-all", "Play / Pause Presentation", "Review", enabled: !(model.manifest?.exportTakes.isEmpty ?? true) && (idle || model.mode == .playing)) { model.play(all: true) },
            .init("back", "Skip Back 10 Seconds", "Review", enabled: model.selectedTake != nil && (idle || model.mode == .playing)) { model.skipPlayback(-10) },
            .init("forward", "Skip Forward 10 Seconds", "Review", enabled: model.selectedTake != nil && (idle || model.mode == .playing)) { model.skipPlayback(10) },
            .init("marker", "Add Review Marker Here", "Review", enabled: model.selectedTake != nil && idle) { model.addReviewMarker("Review this moment") },
            .init("practice", "Practice / End Rehearsal", "Presenting", key: "⌥⌘R", enabled: hasProject && (idle || model.mode == .rehearsing), action: model.togglePractice),
            .init("audience", "Open Audience Display", "Presenting", enabled: hasProject, action: model.showAudienceDisplay),
            .init("prompter", "Pause / Resume Teleprompter", "Presenting", enabled: hasProject, action: model.togglePrompter),
            .init("notes", "Show Presenter Notes", "Presenting", key: "⇧⌘N", enabled: hasProject) { model.showNotes = true; model.hideInspector = false },
            .init("takes", "Show Take Review", "Review", enabled: hasProject) { model.showNotes = false; model.hideInspector = false },
            .init("notes-export", "Export Presenter Notes…", "Presenting", enabled: hasProject && idle, action: model.exportNotes),
            .init("rehearsals", "View Rehearsal Reports", "Presenting", enabled: hasProject) { model.showRehearsalHistory = true },
            .init("export", "Export Video or Audio…", "Export", enabled: !(model.manifest?.exportTakes.isEmpty ?? true) && idle) { model.exportSummary = true },
            .init("cancel-export", "Cancel Export", "Export", enabled: model.mode == .exporting, action: model.cancelExport),
            .init("pages-sidebar", "Show / Hide Page Sidebar", "Layout", key: "⇧⌘F") { model.focusMode.toggle() },
            .init("inspector", "Show / Hide Notes and Take Sidebar", "Layout") { model.hideInspector.toggle() },
            .init("large-controls", "Use Larger / Standard Controls", "Accessibility") { model.largeControls.toggle() }
        ]
        values += InkTool.allCases.map { tool in
            PaletteCommand("tool-\(tool.rawValue)", tool.commandTitle, "Tools", key: "\(tool.canvasKey) in canvas", enabled: model.canDraw) { model.tool = tool }
        }
        return values
    }
    private var visible: [PaletteCommand] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return commands.filter { command in
            terms.allSatisfy { "\(command.title) \(command.category)".localizedStandardContains(String($0)) }
        }
    }
    private var selected: PaletteCommand? { visible.first { $0.id == selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Search commands, tools and shortcuts", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onSubmit(runSelected)
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                Button { model.showCommands = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Close commands").accessibilityLabel("Close commands").keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            ScrollViewReader { reader in
                List(selection: $selectedID) {
                    ForEach(visible) { command in
                        Button { run(command) } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title).foregroundStyle(command.enabled ? .primary : .secondary)
                                    Text(command.category + (command.enabled ? "" : " · Unavailable right now")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(command.key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!command.enabled)
                            .tag(command.id).id(command.id)
                    }
                }.listStyle(.inset)
                    .overlay { if visible.isEmpty { ContentUnavailableView.search(text: query) } }
                    .onChange(of: selectedID) { _, id in if let id { reader.scrollTo(id) } }
            }
            Divider()
            HStack {
                Text("↑ ↓ select · Return run · Escape close").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Run Command", action: runSelected).keyboardShortcut(.defaultAction).disabled(selected?.enabled != true)
            }.padding(14)
        }.frame(width: 600, height: 500)
            .onAppear { searchFocused = true; selectedID = visible.first(where: \.enabled)?.id }
            .onChange(of: query) { _, _ in selectedID = visible.first(where: \.enabled)?.id }
    }
    private func moveSelection(_ direction: Int) {
        let available = visible.filter(\.enabled)
        guard !available.isEmpty else { return }
        let current = available.firstIndex { $0.id == selectedID } ?? (direction > 0 ? -1 : available.count)
        selectedID = available[max(0, min(available.count - 1, current + direction))].id
    }
    private func runSelected() { if let selected { run(selected) } }
    private func run(_ command: PaletteCommand) {
        guard command.enabled else { return }
        model.showCommands = false
        // Let this sheet close before an action opens another sheet or a native file panel.
        Task { @MainActor in
            await Task.yield()
            command.action()
        }
    }
}
