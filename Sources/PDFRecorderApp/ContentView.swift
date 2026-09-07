import SwiftUI
import PDFRecorderCore

private let accent = Color(red: 0.22, green: 0.42, blue: 0.96)

@MainActor struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var pageNumber = "1"
    @FocusState private var searchFocused: Bool
    @State private var showOutline = false
    var body: some View {
        Group {
            if model.manifest == nil { welcome }
            else { workspace }
        }
        .tint(accent)
        .frame(minWidth: model.focusMode || model.hideInspector ? 620 : 760, minHeight: 620)
        .controlSize(model.largeControls ? .large : .regular)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: model.openPanel) { Label("Open", systemImage: "folder") }.disabled(model.mode != .idle).help("Open PDF or project (⌘O)")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(model.manifest?.title ?? "PDF Recorder").font(.headline).lineLimit(1)
                    if model.manifest != nil { Text(model.isRecoveryProject ? "Autosaved on this Mac · Save Project to choose a location" : "All takes saved on this Mac").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.manifest != nil {
                    Button { model.focusMode.toggle() } label: { Label("Focus", systemImage: model.focusMode ? "sidebar.left" : "rectangle.center.inset.filled") }.help("Show or hide page sidebar")
                    Button { model.hideInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }.help("Show or hide notes and takes")
                    Button("Save Project", systemImage: "square.and.arrow.down", action: model.saveAs).disabled(model.mode != .idle)
                    Button("Export", systemImage: "square.and.arrow.up") { model.exportSummary = true }
                        .disabled(model.mode != .idle || model.manifest?.selectedTakes.isEmpty != false)
                }
            }
        }
        .alert("PDF Recorder", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.exportSummary) { ExportSettingsView(model: model) }
        .sheet(isPresented: $model.showStorage) { StorageCenterView(model: model) }
        .sheet(isPresented: $model.showCommands) { CommandPaletteView(model: model) }
        .sheet(isPresented: $model.showRehearsalHistory) { RehearsalHistoryView(model: model) }
        .onChange(of: model.focusSearchToken) { _, _ in model.focusMode = false; searchFocused = true }
        .sheet(isPresented: Binding(get: { model.mode == .exporting }, set: { _ in })) { exportProgress }
        .sheet(isPresented: $model.showRecovery) { recovery }
        .onChange(of: model.pageIndex) { _, _ in pageNumber = model.pageLabel }
        .onChange(of: model.manifest?.id) { _, _ in pageNumber = model.pageLabel }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.mode == .idle, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.open(url) } }
            }
            return true
        }
    }
    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()
            Button(action: model.openPanel) { RareFolder() }.buttonStyle(.plain).accessibilityLabel("Open a PDF or saved project")
            VStack(spacing: 12) {
                Text("Your PDF. Your explanation.").font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Record one page at a time. Keep the best takes.\nTurn your notes into a presentation worth sharing.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            Button(action: model.openPanel) { Label("Open a PDF", systemImage: "plus").font(.headline).padding(.horizontal, 22).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("or drop a PDF or saved project anywhere").font(.callout).foregroundStyle(.secondary)
            if !model.recentProjects.isEmpty { RecentProjectsView(model: model).frame(maxWidth: 980).padding(.horizontal, 30) }
            HStack(spacing: 40) {
                feature("mic", "Voice & gestures")
                feature("square.stack", "Takes for every page")
                feature("arrow.up.right.video", "One finished video")
            }.padding(.top, 18)
            Spacer()
            Label("Private by design. Everything stays on your Mac.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func feature(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 9) { Image(systemName: icon).font(.title2).foregroundStyle(accent); Text(title).font(.callout) }
    }
    private var workspace: some View {
        HSplitView {
            if !model.focusMode { pageSidebar.frame(minWidth: 150, idealWidth: 196, maxWidth: 260) }
            VStack(spacing: 0) {
                canvasToolbar
                Divider()
                VStack(spacing: 14) {
                    HStack {
                        Label(modeLabel, systemImage: model.isRecording ? "record.circle" : "doc.text")
                            .font(.caption.weight(.semibold)).foregroundStyle(model.isRecording ? Color.red : Color.secondary)
                        Spacer()
                        PaceIndicator(model: model)
                        Text("PAGE \(model.pageLabel)").font(.caption.monospaced().weight(.medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    PDFCanvas(model: model).aspectRatio(16.0 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.1), radius: 14, y: 5)
                        .overlay {
                            if model.mode == .countdown {
                                VStack(spacing: 12) {
                                    Text("\(model.countdownRemaining)").font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
                                    Text("Get ready to explain").font(.headline)
                                    Button("Cancel", action: model.cancelCountdown).buttonStyle(.bordered)
                                }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                            }
                        }
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        Button { model.navigate(to: model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.canNavigate || model.pageIndex == 0)
                        HStack(spacing: 4) {
                            TextField("Page", text: $pageNumber).frame(width: 35).multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder).disabled(!model.canNavigate)
                                .onSubmit {
                                    model.navigate(toLabel: pageNumber)
                                    pageNumber = model.pageLabel
                                }
                            Text("of \(model.manifest?.pages.count ?? 0)").foregroundStyle(.secondary)
                        }.font(.caption)
                        Button { model.navigate(to: model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.canNavigate || model.pageIndex + 1 >= (model.manifest?.pages.count ?? 0))
                        Spacer()
                        Text(model.mode == .paused ? "Paused · resume to draw or move" : "Pinch to zoom · scroll to pan")
                            .font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                transport
            }.frame(minWidth: 340)
            if !model.hideInspector { takeSidebar.frame(minWidth: 220, idealWidth: 300, maxWidth: 550) }
        }
    }
    private var modeLabel: String {
        switch model.mode {
        case .recording: return "RECORDING"
        case .paused: return "PAUSED"
        case .playing: return "PLAYBACK"
        case .starting: return "STARTING MICROPHONE"
        case .stopping: return "SAVING TAKE"
        case .countdown: return "GET READY"
        case .rehearsing: return "PRACTICE · MICROPHONE OFF"
        default: return "READY TO EXPLAIN"
        }
    }
    private var pageSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                HStack { Text("Pages").font(.headline); Spacer(); Text("\(model.manifest?.selectedTakes.count ?? 0)/\(model.manifest?.pages.count ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                ProgressView(value: Double(model.manifest?.selectedTakes.count ?? 0), total: Double(max(1, model.manifest?.pages.count ?? 1)))
                TextField("Search pages & notes", text: $model.searchQuery).textFieldStyle(.roundedBorder).disabled(!model.canNavigate).focused($searchFocused)
                Picker("Filter pages", selection: $model.pageFilter) { ForEach(PageFilter.allCases) { filter in Text(filter.rawValue).tag(filter) } }
                    .labelsHidden().disabled(!model.canNavigate)
                if model.isSearching { Text("Searching PDF text…").font(.caption2).foregroundStyle(.secondary) }
                DisclosureGroup("Document outline", isExpanded: $showOutline) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            if model.outlineItems.isEmpty { Text("This PDF has no outline.").font(.caption2).foregroundStyle(.secondary) }
                            ForEach(model.outlineItems) { item in Button(item.title) { model.navigate(to: item.page) }.buttonStyle(.plain).font(.caption).padding(.leading, CGFloat(min(4, item.depth)) * 8).disabled(!model.canNavigate) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }.font(.caption)
                if let progress = model.ocrProgress {
                    ProgressView(value: progress)
                    Button("Cancel Text Recognition") { model.ocrTask?.cancel() }.font(.caption)
                } else { Button("Recognize Scanned Text", action: model.startOCR).font(.caption).disabled(model.mode != .idle) }
                Button("Next Unrecorded", systemImage: "arrow.right.circle", action: model.nextUnrecorded).font(.caption).disabled(!model.canNavigate)
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if model.visiblePageIndices.isEmpty { Text("No matching pages").font(.callout).foregroundStyle(.secondary).padding() }
                        ForEach(model.visiblePageIndices, id: \.self) { index in
                            Button { model.navigate(to: index) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
                                        if let image = model.thumbnail(index) { Image(nsImage: image).resizable().scaledToFit().padding(3) }
                                    }.frame(height: 102).clipShape(RoundedRectangle(cornerRadius: 5))
                                    HStack {
                                        Text(model.pageTitle(index)).font(.caption.weight(.medium)).lineLimit(1)
                                        if model.manifest?.pages[index].bookmarked == true { Image(systemName: "bookmark.fill").foregroundStyle(accent) }
                                        Spacer()
                                        if let take = model.manifest?.pages[index].selectedTake {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                            Text(duration(take.playbackDuration)).monospacedDigit()
                                        } else { Text("Not recorded").foregroundStyle(.secondary) }
                                    }.font(.caption2)
                                    if model.manifest?.pages[index].includedInExport == false { Text("Excluded from export").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(8)
                                    .background(index == model.pageIndex ? accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(index == model.pageIndex ? accent : Color.primary.opacity(0.08), lineWidth: index == model.pageIndex ? 2 : 1))
                            }.buttonStyle(.plain).disabled(!model.canNavigate).id(index)
                                .accessibilityLabel("Page \(index + 1), \(model.pageTitle(index)), \(model.manifest?.pages[index].selectedTake == nil ? "not recorded" : "recorded")")
                                .accessibilityAddTraits(index == model.pageIndex ? .isSelected : [])
                        }
                    }.padding(12)
                }.onChange(of: model.pageIndex) { _, index in withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }.background(.ultraThinMaterial)
    }
    private var canvasToolbar: some View {
        VStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(InkTool.allCases, id: \.self) { tool in
                        Button { model.tool = tool } label: {
                            Image(systemName: toolIcon(tool)).frame(width: 30, height: 30)
                                .foregroundStyle(model.tool == tool ? accent : Color.primary)
                                .background(model.tool == tool ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).help("\(tool.commandTitle) (\(tool.canvasKey))").accessibilityLabel(tool.commandTitle)
                            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                    }
                    Divider().frame(height: 22)
                    Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.help("Undo mark").disabled(model.groupedUndoActions.isEmpty)
                    Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }.help("Redo mark").disabled(model.redoActions.isEmpty)
                    Button("Clear", action: model.clearMarks).font(.caption).disabled(model.scene.strokes.isEmpty)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
                Menu("Ink") { ForEach(["blue", "red", "yellow", "green", "purple"], id: \.self) { color in Button(color.capitalized) { model.inkColor = color } } }.frame(width: 54)
                Menu("Width") { ForEach(Array(["Fine", "Regular", "Bold", "Broad"].enumerated()), id: \.offset) { index, label in Button(label) { model.annotationWidth = [0.0015, 0.003, 0.006, 0.012][index] } } }.frame(width: 64)
                Slider(value: $model.annotationOpacity, in: 0.1...1).frame(maxWidth: 85).help("Ink opacity").accessibilityLabel("Ink opacity")
                if model.tool == .text { TextField("Text label", text: $model.annotationText).textFieldStyle(.roundedBorder).frame(maxWidth: 150) }
                Spacer(minLength: 0)
                Button { model.zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Text("\(Int(model.scene.viewport.zoom * 100))%").font(.caption.monospacedDigit())
                Button { model.zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                Button("Fit", action: model.fit).font(.caption)
            } }
        }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 6).disabled(!model.canDraw)
    }
    private var transport: some View {
        VStack(spacing: 13) {
            if model.selectedTake != nil, model.mode == .idle || model.mode == .playing {
                WaveformTimelineView(model: model)
                HStack {
                    Button { model.skipPlayback(-10) } label: { Label("Back 10s", systemImage: "gobackward.10") }
                    Button { model.skipPlayback(10) } label: { Label("Forward 10s", systemImage: "goforward.10") }
                    Spacer()
                    Picker("Playback speed", selection: $model.playbackRate) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { speed in Text("\(speed, specifier: "%g")×").tag(speed) }
                    }.frame(width: 150)
                }.font(.caption).buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                if model.mode == .checkingMicrophone {
                    Button("Stop Microphone Check") { Task { await model.stopMicrophoneCheck() } }.buttonStyle(.borderedProminent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.microphone.snapshot.deviceName).font(.caption.weight(.semibold)).lineLimit(1)
                            .accessibilityLabel("Active microphone: \(model.microphone.snapshot.deviceName)")
                        Text(model.microphoneFeedback).font(.caption).lineLimit(3)
                    }
                } else if model.mode == .loadingPlayback {
                    ProgressView().controlSize(.small)
                    Text("Preparing playback…").font(.caption)
                    Button("Cancel", action: model.stopPlayback)
                } else if model.mode == .countdown {
                    Button("Cancel Countdown", action: model.cancelCountdown)
                    Text("Microphone starts after the countdown").font(.caption).foregroundStyle(.secondary)
                } else if model.mode == .rehearsing {
                    Button(action: model.togglePractice) { Label("End Practice", systemImage: "stop.fill") }.buttonStyle(.borderedProminent)
                    Text(duration(model.time)).font(.title3.monospacedDigit())
                    Text("Microphone off · no take saved").font(.caption).foregroundStyle(.secondary)
                } else if model.isRecording {
                    Button { model.togglePause() } label: { Label(model.mode == .paused ? "Resume" : "Pause", systemImage: model.mode == .paused ? "play.fill" : "pause.fill") }
                        .disabled(model.mode == .starting || model.mode == .stopping)
                    Button { Task { await model.stopRecording() } } label: { Label("Stop & Save", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(model.mode == .starting || model.mode == .stopping)
                    Text(duration(model.time)).font(.system(.title3, design: .monospaced).weight(.medium))
                } else {
                    Button(action: model.record) { Label(model.page?.takes.isEmpty == false ? "New Take" : "Record Page", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(model.mode != .idle)
                    Button { model.play(all: model.playbackPaused && model.playbackIsPresentation) } label: { Label(model.mode == .playing ? "Pause" : (model.playbackPaused ? "Resume" : "Play Take"), systemImage: model.mode == .playing ? "pause.fill" : "play.fill") }
                        .disabled(model.selectedTake == nil || model.mode == .exporting)
                    Button(action: model.togglePractice) { Image(systemName: "timer") }.help("Practice without recording").disabled(model.mode != .idle)
                }
            }.controlSize(model.largeControls ? .large : .regular)
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<12) { i in Capsule().fill(model.level > Double(i) / 12 ? (i > 9 ? Color.orange : Color.green) : Color.primary.opacity(0.1)).frame(width: 4, height: 5 + CGFloat(i) * 1.1) }
                }.accessibilityLabel("Microphone level \(Int(model.level * 100)) percent")
                Spacer()
                if model.mode == .checkingMicrophone { Text("No audio saved").font(.caption2).foregroundStyle(.secondary) }
            }.controlSize(model.largeControls ? .large : .regular)
            HStack {
                Text(model.isRecording ? "This page is locked until you stop recording." : (model.status.isEmpty ? "Each new take keeps your previous recordings." : model.status))
                Spacer()
                Button("Commands") { model.showCommands = true }.buttonStyle(.link)
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(18).background(.bar)
    }
    private var takeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Inspector", selection: $model.showNotes) { Text("Takes").tag(false); Text("Notes & Timing").tag(true) }.pickerStyle(.segmented).padding(12)
            if model.showNotes { PresenterNotesView(model: model) } else { TakeBrowserView(model: model) }
            Divider()
            RecordingSettingsView(model: model)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var exportProgress: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(accent)
            Text(model.exportKind == .video ? "Making your video" : "Exporting your audio").font(.title2.weight(.semibold))
            Text("Rendering locally on your Mac.").foregroundStyle(.secondary)
            ProgressView(value: model.exportProgress)
            Text("\(Int(model.exportProgress * 100))%").monospacedDigit()
            if let remaining = model.exportRemaining { Text("About \(duration(remaining)) remaining").font(.caption).foregroundStyle(.secondary) }
            Button("Cancel Export", action: model.cancelExport)
        }.padding(36).frame(width: 390).interactiveDismissDisabled()
    }
    private var recovery: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Continue where you left off").font(.title2.weight(.semibold))
            Text("These projects were autosaved on this Mac. Open one to continue or recover an interrupted take.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.recoveryProjects, id: \.self) { url in
                        Button { model.showRecovery = false; model.open(url) } label: {
                            HStack { Image(systemName: "doc.richtext"); Text(url.deletingPathExtension().lastPathComponent).lineLimit(1); Spacer(); Image(systemName: "arrow.right") }.padding(12)
                        }.buttonStyle(.bordered)
                    }
                }
            }.frame(maxHeight: 240)
            HStack { Spacer(); Button("Start Fresh") { model.showRecovery = false } }
        }.padding(28).frame(width: 500)
    }
    private func toolIcon(_ tool: InkTool) -> String {
        switch tool { case .pointer: return "cursorarrow"; case .pen: return "pencil.tip"; case .highlighter: return "highlighter"; case .eraser: return "eraser"; case .pan: return "hand.draw"; case .line: return "line.diagonal"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .ellipse: return "circle"; case .text: return "textformat"; case .selectText: return "text.cursor" }
    }
}

func duration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
