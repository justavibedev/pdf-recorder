import SwiftUI
import PDFRecorderCore

private let accent = StudioTheme.text

@MainActor struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var pageNumber = "1"
    @FocusState private var searchFocused: Bool
    @State private var showOutline = false
    @State private var showInk = false
    private let primaryTools: [InkTool] = [.pointer, .pen, .highlighter, .eraser, .pan]
    private var pageCount: Int { model.currentDocument?.pageCount ?? model.manifest?.pages.count ?? 0 }
    var body: some View {
        Group {
            if model.manifest == nil { welcome }
            else { VStack(spacing: 0) { documentTabs; workspace } }
        }
        .tint(accent)
        .frame(minWidth: model.focusMode || model.hideInspector ? 620 : 760, minHeight: 580)
        .controlSize(model.largeControls ? .large : .regular)
        .background(StudioTheme.background)
        .foregroundStyle(StudioTheme.text)
        .preferredColorScheme(.dark)
        .buttonStyle(StudioButtonStyle())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: model.showLibrary) { Label("PDF Recorder", systemImage: "square.stack.3d.up").font(.system(size: 12, weight: .semibold)) }.buttonStyle(StudioButtonStyle(kind: .ghost)).disabled(model.mode != .idle).help("Project library")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Text(model.manifest?.title ?? "Your presentation studio").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if model.manifest != nil { Image(systemName: model.hasUnsavedMetadata ? "circle.dotted" : "checkmark.circle").font(.system(size: 10)).help(model.hasUnsavedMetadata ? "Saving changes" : "Saved on this Mac") }
                }.foregroundStyle(StudioTheme.muted)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.manifest != nil {
                    Button { model.focusMode.toggle() } label: { Image(systemName: "sidebar.left") }.help("Show or hide page sidebar").accessibilityLabel(model.focusMode ? "Show page sidebar" : "Hide page sidebar")
                    Button { model.hideInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Show or hide notes and takes").accessibilityLabel(model.hideInspector ? "Show notes and takes" : "Hide notes and takes")
                    Menu {
                        Button("Save Project As…", action: model.saveAs).disabled(model.mode != .idle)
                        Button("Add PDFs…", action: model.addPDFPanel).disabled(model.mode != .idle)
                        Button("Open Another Project…", action: model.openPanel).disabled(model.mode != .idle)
                        Divider()
                        Button("Storage & Recovery…", action: model.refreshStorage).disabled(model.mode != .idle)
                        Button("Show Project in Finder", action: model.revealProject)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).help("Project actions").accessibilityLabel("Project actions")
                    Button("Export", systemImage: "arrow.up.right") { model.exportSummary = true }.buttonStyle(StudioButtonStyle(kind: .primary))
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
        .onChange(of: model.currentDocumentID) { _, _ in pageNumber = model.pageLabel }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.mode == .idle, !providers.isEmpty else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                if !urls.isEmpty { model.openURLs(urls) }
            }
            return true
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    Button(action: model.openPanel) { RareFolder() }.buttonStyle(.plain).accessibilityLabel("Open PDFs or a saved project")
                    Text("A clearer way to present.").font(.system(size: 31, weight: .semibold)).tracking(-0.7)
                    Text("Open your PDFs. Record each page. Keep the best take.")
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.muted).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button(action: model.openPanel) { Label("Open PDFs", systemImage: "plus") }.buttonStyle(StudioButtonStyle(kind: .primary)).controlSize(.large)
                        StudioBadge(text: "⌘ O")
                    }.padding(.top, 5)
                    Text("or drop PDFs anywhere").font(.system(size: 11)).foregroundStyle(StudioTheme.faint)
                }.padding(.top, model.recentProjects.isEmpty ? 50 : 20).padding(.bottom, 36)
                if !model.recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("RECENT PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(StudioTheme.faint)
                        RecentProjectsView(model: model)
                    }.frame(maxWidth: 940).padding(.horizontal, 34)
                }
                Label("Private. Offline. Yours.", systemImage: "lock").font(.system(size: 11)).foregroundStyle(StudioTheme.faint).padding(.vertical, 30)
            }.frame(maxWidth: .infinity)
        }
    }
    private var documentTabs: some View {
        GeometryReader { geometry in
            let limit = max(1, min(6, Int((geometry.size.width - 82) / 146)))
            let tabs = visibleDocuments(limit: limit)
            let overflow = model.pdfDocuments.filter { document in !tabs.contains { $0.id == document.id } }
            HStack(spacing: 3) {
                ForEach(tabs) { document in
                    Button { model.selectDocument(document.id) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text").font(.system(size: 11))
                            Text(document.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("\(document.pageCount)").font(.system(size: 9)).foregroundStyle(StudioTheme.faint)
                        }.padding(.horizontal, 12).frame(minWidth: 95, maxWidth: 168, minHeight: 32)
                            .foregroundStyle(document.id == model.currentDocumentID ? StudioTheme.text : StudioTheme.muted)
                            .background(document.id == model.currentDocumentID ? StudioTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(document.id == model.currentDocumentID ? StudioTheme.border : .clear))
                    }.buttonStyle(.plain).disabled(!model.canNavigate)
                        .help("\(document.title) · \(document.pageCount) pages")
                        .accessibilityLabel("PDF: \(document.title), \(document.pageCount) pages")
                        .accessibilityAddTraits(document.id == model.currentDocumentID ? .isSelected : [])
                }
                if !overflow.isEmpty {
                    Menu { ForEach(overflow) { document in Button("\(document.title) · \(document.pageCount) pages") { model.selectDocument(document.id) } } }
                    label: { Text("+\(overflow.count)").font(.system(size: 11)) }
                        .menuStyle(.borderlessButton).frame(width: 36).disabled(!model.canNavigate).help("More PDFs").accessibilityLabel("\(overflow.count) more PDFs")
                }
                Button(action: model.addPDFPanel) { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(StudioButtonStyle(kind: .ghost)).disabled(model.mode != .idle).help("Add PDFs to this project").accessibilityLabel("Add PDFs to this project")
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(height: 44)
        }.frame(height: 44).background(StudioTheme.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }
    }
    private func visibleDocuments(limit: Int) -> [ProjectPDFDocument] {
        var result = Array(model.pdfDocuments.prefix(limit))
        if let current = model.currentDocument, !result.contains(where: { $0.id == current.id }), !result.isEmpty { result[result.count - 1] = current }
        return result
    }
    private var workspace: some View {
        HSplitView {
            if !model.focusMode { pageSidebar.frame(minWidth: 154, idealWidth: 194, maxWidth: 260) }
            VStack(spacing: 0) {
                canvasToolbar
                Divider()
                VStack(spacing: 14) {
                    HStack {
                        Label(modeLabel, systemImage: model.isRecording ? "record.circle" : "doc.text")
                            .font(.caption.weight(.semibold)).foregroundStyle(model.isRecording ? Color.red : Color.secondary)
                        Spacer()
                        PaceIndicator(model: model)

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
                            .disabled(!model.canNavigate || model.pageIndex <= model.currentDocumentPages.lowerBound)
                            .help("Previous page (⌘←)").accessibilityLabel("Previous page")
                        HStack(spacing: 4) {
                            TextField("Page", text: $pageNumber).frame(width: 35).multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder).disabled(!model.canNavigate)
                                .accessibilityLabel("Page number or printed page label within this PDF")
                                .onSubmit {
                                    model.navigate(toLabel: pageNumber)
                                    pageNumber = model.pageLabel
                                }
                            Text("of \(pageCount)").foregroundStyle(.secondary)
                        }.font(.caption)
                        Button { model.navigate(to: model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.canNavigate || model.pageIndex + 1 >= model.currentDocumentPages.upperBound)
                            .help("Next page (⌘→)").accessibilityLabel("Next page")
                        Spacer()
                        Text(model.mode == .paused ? "Paused · resume to draw or move" : "Pinch to zoom")
                            .font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                transport
            }.frame(minWidth: 320).background(StudioTheme.background)
            if !model.hideInspector { takeSidebar.frame(minWidth: 232, idealWidth: 292, maxWidth: 520) }
        }
    }
    private var modeLabel: String {
        switch model.mode {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .playing: return "Review"
        case .starting: return "Starting microphone"
        case .stopping: return "Saving"
        case .savingProject: return "Saving project"
        case .countdown: return "Starting soon"
        case .rehearsing: return "Practice · mic off"
        case .loadingPlayback: return "Preparing playback"
        case .checkingMicrophone: return "Checking microphone"
        default: return "Ready"
        }
    }
    private var pageSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("PAGES").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Text("\(model.currentDocumentRecordedCount)/\(pageCount)").font(.system(size: 10).monospacedDigit())
                    Menu {
                        Picker("Filter", selection: $model.pageFilter) { ForEach(PageFilter.allCases) { Text($0.rawValue).tag($0) } }
                        Divider()
                        Button("Document Outline") { showOutline = true }
                        Button("Next Unrecorded Page", action: model.nextUnrecorded)
                        Divider()
                        Button("Recognize Scanned Text", action: model.startOCR).disabled(model.mode != .idle || model.ocrTask != nil)
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                        .menuStyle(.borderlessButton).frame(width: 18).disabled(!model.canNavigate).help("Page filters and reading tools").accessibilityLabel("Page filters and reading tools")
                }.foregroundStyle(StudioTheme.muted)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.faint)
                    TextField("Find a page…", text: $model.searchQuery).textFieldStyle(.plain).focused($searchFocused).disabled(!model.canNavigate)
                }.font(.system(size: 11)).padding(8).studioPanel(cornerRadius: 6)
                if model.pageFilter != .all {
                    HStack {
                        StudioBadge(text: model.pageFilter.rawValue)
                        Spacer()
                        Button { model.pageFilter = .all } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Clear filter")
                    }
                }
                if model.isSearching { ProgressView("Searching…").font(.caption2).controlSize(.mini) }
                if let progress = model.ocrProgress {
                    HStack { ProgressView(value: progress); Button { model.ocrTask?.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Cancel text recognition") }
                }
            }.padding(14)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        if model.visiblePageIndices.isEmpty { Text("No matching pages").font(.system(size: 12)).foregroundStyle(StudioTheme.muted).padding(.vertical, 22) }
                        ForEach(model.visiblePageIndices, id: \.self) { index in pageCard(index) }
                    }.padding(.horizontal, 12).padding(.bottom, 14)
                }.onChange(of: model.pageIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
            }
        }.background(StudioTheme.sidebar)
            .popover(isPresented: $showOutline) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Document outline").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.outlineItems.isEmpty { Text("This PDF has no outline.").foregroundStyle(StudioTheme.muted) }
                            ForEach(model.outlineItems) { item in Button(item.title) { model.navigate(to: item.page); showOutline = false }.buttonStyle(.plain).font(.system(size: 12)).padding(.leading, CGFloat(min(4, item.depth)) * 10).disabled(!model.canNavigate) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(18).frame(width: 300, height: 320)
            }
    }
    private func pageCard(_ index: Int) -> some View {
        let selected = model.pageIndex == index
        let record = model.manifest?.pages[index]
        let local = index - model.currentDocumentPages.lowerBound + 1
        return Button { model.navigate(to: index) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 4).fill(StudioTheme.background)
                    if let image = model.thumbnail(index) { Image(nsImage: image).resizable().scaledToFit().padding(4) }
                    if record?.selectedTake != nil { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(StudioTheme.text).padding(6).shadow(color: .black.opacity(0.7), radius: 2) }
                }.frame(height: 94).clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 5) {
                    Text(String(format: "%02d", local)).font(.system(size: 10).monospacedDigit()).foregroundStyle(StudioTheme.faint)
                    Text(record?.title?.isEmpty == false ? record!.title! : "Page \(local)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if record?.bookmarked == true { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(StudioTheme.muted) }
                    if let take = record?.selectedTake { Text(duration(take.playbackDuration)).font(.system(size: 9).monospacedDigit()).foregroundStyle(StudioTheme.muted) }
                }
                if record?.includedInExport == false { Text("Excluded from export").font(.system(size: 9)).foregroundStyle(StudioTheme.faint) }
            }.padding(8)
                .background(selected ? StudioTheme.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.white.opacity(0.35) : StudioTheme.border))
        }.buttonStyle(.plain).disabled(!model.canNavigate).id(index)
            .accessibilityLabel("Page \(local), \(model.pageTitle(index)), \(record?.selectedTake == nil ? "not recorded" : "recorded")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var canvasToolbar: some View {
        HStack(spacing: 3) {
            ForEach(primaryTools, id: \.self) { tool in toolButton(tool) }
            Menu {
                ForEach(InkTool.allCases.filter { !primaryTools.contains($0) }, id: \.self) { tool in Button { model.tool = tool } label: { Label(tool.commandTitle, systemImage: toolIcon(tool)) } }
                Divider()
                Button("Undo Mark", action: model.undo).disabled(model.groupedUndoActions.isEmpty)
                Button("Redo Mark", action: model.redo).disabled(model.redoActions.isEmpty)
                Button("Clear Marks", action: model.clearMarks).disabled(model.scene.strokes.isEmpty)
            } label: { Image(systemName: primaryTools.contains(model.tool) ? "square.on.circle" : toolIcon(model.tool)).frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).frame(width: 27).help("More tools, undo and redo").accessibilityLabel("More annotation tools, undo and redo")
            Rectangle().fill(StudioTheme.border).frame(width: 1, height: 18).padding(.horizontal, 4)
            Button { showInk.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 25, height: 28) }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.muted).help("Ink options").accessibilityLabel("Ink options")
                .popover(isPresented: $showInk) { inkOptions }
            Spacer(minLength: 2)
            Menu {
                Button("Zoom In") { model.zoom(1.25) }
                Button("Zoom Out") { model.zoom(1 / 1.25) }
                Button("Fit Page", action: model.fit)
            } label: { Text("\(Int(model.scene.viewport.zoom * 100))%").font(.system(size: 11).monospacedDigit()) }
                .menuStyle(.borderlessButton).frame(width: 53).help("Zoom").accessibilityLabel("Zoom, \(Int(model.scene.viewport.zoom * 100)) percent")
        }.padding(.horizontal, 12).frame(height: 46).background(StudioTheme.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioTheme.border).frame(height: 1) }.disabled(!model.canDraw)
    }
    private func toolButton(_ tool: InkTool) -> some View {
        Button { model.tool = tool } label: {
            Image(systemName: toolIcon(tool)).font(.system(size: 12)).frame(width: model.largeControls ? 31 : 27, height: 28)
                .foregroundStyle(model.tool == tool ? StudioTheme.text : StudioTheme.muted)
                .background(model.tool == tool ? StudioTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).help("\(tool.commandTitle) (\(tool.canvasKey))").accessibilityLabel(tool.commandTitle)
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
    }
    private var inkOptions: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Ink options").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                ForEach(["blue", "red", "yellow", "green", "purple"], id: \.self) { color in
                    Button { model.inkColor = color } label: {
                        Circle().fill(Color(cgColor: SceneRenderer.color(color))).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.white, lineWidth: model.inkColor == color ? 2 : 0))
                    }.buttonStyle(.plain).help(color.capitalized).accessibilityLabel("\(color.capitalized) ink")
                        .accessibilityAddTraits(model.inkColor == color ? .isSelected : [])
                }
            }
            Picker("Width", selection: $model.annotationWidth) {
                ForEach(Array(["Fine", "Regular", "Bold", "Broad"].enumerated()), id: \.offset) { index, label in Text(label).tag([0.0015, 0.003, 0.006, 0.012][index]) }
            }.font(.system(size: 12))
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Opacity"); Spacer(); Text("\(Int(model.annotationOpacity * 100))%").foregroundStyle(StudioTheme.muted) }.font(.system(size: 11))
                Slider(value: $model.annotationOpacity, in: 0.1...1).accessibilityLabel("Ink opacity")
            }
            TextField("Text label", text: $model.annotationText).textFieldStyle(.roundedBorder)
            Text("Choose Text from More tools, then click the page.").font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
        }.padding(18).frame(width: 240).background(StudioTheme.sidebar)
    }
    private var transport: some View {
        VStack(spacing: 13) {
            if model.selectedTake != nil, model.mode == .idle || model.mode == .playing {
                WaveformTimelineView(model: model)
                HStack {
                    Button { model.skipPlayback(-10) } label: { Image(systemName: "gobackward.10") }.help("Back 10 seconds").accessibilityLabel("Back 10 seconds")
                    Button { model.skipPlayback(10) } label: { Image(systemName: "goforward.10") }.help("Forward 10 seconds").accessibilityLabel("Forward 10 seconds")
                    Spacer()
                    Picker("Playback speed", selection: $model.playbackRate) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { speed in Text("\(speed, specifier: "%g")×").tag(speed) }
                    }.frame(width: 150)
                }.font(.caption).buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                if model.mode == .checkingMicrophone {
                    Button("Stop Check") { Task { await model.stopMicrophoneCheck() } }.buttonStyle(StudioButtonStyle(kind: .primary))
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
                    Button(action: model.togglePractice) { Label("End Practice", systemImage: "stop.fill") }.buttonStyle(StudioButtonStyle(kind: .primary))
                    Text(duration(model.time)).font(.title3.monospacedDigit())

                } else if model.mode == .savingProject {
                    ProgressView().controlSize(.small)
                    Text("Saving project…").font(.caption)
                } else if model.isRecording {
                    Button { model.togglePause() } label: { Label(model.mode == .paused ? "Resume" : "Pause", systemImage: model.mode == .paused ? "play.fill" : "pause.fill") }
                        .disabled(model.mode == .starting || model.mode == .stopping)
                    Button { Task { await model.stopRecording() } } label: { Label("Stop & Save", systemImage: "stop.fill") }
                        .buttonStyle(StudioButtonStyle(kind: .record)).disabled(model.mode == .starting || model.mode == .stopping)
                    Text(duration(model.time)).font(.system(.title3, design: .monospaced).weight(.medium))
                } else {
                    Button(action: model.record) { Label(model.page?.takes.isEmpty == false ? "New Take" : "Record", systemImage: "record.circle") }
                        .buttonStyle(StudioButtonStyle(kind: .record)).disabled(model.mode != .idle)
                    Button { model.play(all: model.playbackPaused && model.playbackIsPresentation) } label: { Image(systemName: model.mode == .playing ? "pause.fill" : "play.fill") }.help(model.mode == .playing ? "Pause playback" : "Play take").accessibilityLabel(model.mode == .playing ? "Pause playback" : "Play take")
                        .disabled(model.selectedTake == nil || model.mode == .exporting)
                    Button(action: model.togglePractice) { Image(systemName: "timer") }.help("Practice without recording").accessibilityLabel("Practice without recording").disabled(model.mode != .idle)
                }
            }.controlSize(model.largeControls ? .large : .regular)
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<12) { i in Capsule().fill(model.level > Double(i) / 12 ? StudioTheme.text : StudioTheme.elevated).frame(width: 4, height: 5 + CGFloat(i) * 1.1) }
                }.accessibilityLabel("Microphone level \(Int(model.level * 100)) percent")
                Spacer()
                if model.mode == .checkingMicrophone { Text("No audio saved").font(.caption2).foregroundStyle(.secondary) }
            }.controlSize(model.largeControls ? .large : .regular)
            HStack {
                Text(model.isRecording ? "Page locked while recording" : (model.status.isEmpty ? "Saved on this Mac" : model.status))
                Spacer()
                Button("⌘ K") { model.showCommands = true }.buttonStyle(.plain).help("Search commands").accessibilityLabel("Search commands")
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(14).background(StudioTheme.sidebar)
    }
    private var takeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) { inspectorTab("Takes", notes: false); inspectorTab("Notes", notes: true); Spacer() }.padding(12)
            if model.showNotes { PresenterNotesView(model: model) } else { TakeBrowserView(model: model) }
            Divider()
            RecordingSettingsView(model: model)
        }.background(StudioTheme.sidebar)
    }
    private func inspectorTab(_ title: String, notes: Bool) -> some View {
        Button { model.showNotes = notes } label: {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(model.showNotes == notes ? StudioTheme.text : StudioTheme.muted)
                .background(model.showNotes == notes ? StudioTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(model.showNotes == notes ? .isSelected : [])
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
        }.padding(30).frame(width: 390).background(StudioTheme.sidebar).interactiveDismissDisabled()
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
        }.padding(28).frame(width: 500).background(StudioTheme.sidebar)
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
