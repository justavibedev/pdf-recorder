import SwiftUI
import PDFRecorderCore

private let accent = Color(red: 0.22, green: 0.42, blue: 0.96)

@MainActor struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var pageNumber = "1"
    var body: some View {
        Group {
            if model.manifest == nil { welcome }
            else { workspace }
        }
        .tint(accent)
        .frame(minWidth: 1080, minHeight: 700)
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
                    Button("Save Project", systemImage: "square.and.arrow.down", action: model.saveAs).disabled(model.mode != .idle)
                    Button("Export", systemImage: "square.and.arrow.up") { model.exportSummary = true }
                        .disabled(model.mode != .idle || model.manifest?.exportTakes.isEmpty != false)
                }
            }
        }
        .alert("PDF Recorder", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.exportSummary) { exportConfirmation }
        .sheet(isPresented: Binding(get: { model.mode == .exporting }, set: { _ in })) { exportProgress }
        .sheet(isPresented: $model.showRecovery) { recovery }
        .onChange(of: model.pageIndex) { _, index in pageNumber = String(index + 1) }
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
            if !model.focusMode { pageSidebar.frame(minWidth: 170, idealWidth: 196, maxWidth: 250) }
            VStack(spacing: 0) {
                canvasToolbar
                Divider()
                VStack(spacing: 14) {
                    HStack {
                        Label(modeLabel, systemImage: model.isRecording ? "record.circle" : "doc.text")
                            .font(.caption.weight(.semibold)).foregroundStyle(model.isRecording ? Color.red : Color.secondary)
                        Spacer()
                        PaceIndicator(model: model)
                        Text("PAGE \(model.pageIndex + 1)").font(.caption.monospaced().weight(.medium)).foregroundStyle(.secondary)
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
                                    if let number = Int(pageNumber) { model.navigate(to: number - 1) }
                                    pageNumber = String(model.pageIndex + 1)
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
            }.frame(minWidth: 600)
            takeSidebar.frame(minWidth: 230, idealWidth: 246, maxWidth: 300)
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
                TextField("Search pages & notes", text: $model.searchQuery).textFieldStyle(.roundedBorder).disabled(!model.canNavigate)
                Picker("Filter pages", selection: $model.pageFilter) { ForEach(PageFilter.allCases) { filter in Text(filter.rawValue).tag(filter) } }
                    .labelsHidden().disabled(!model.canNavigate)
                if model.isSearching { Text("Searching PDF text…").font(.caption2).foregroundStyle(.secondary) }
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
                                            Text(duration(take.duration)).monospacedDigit()
                                        } else { Text("Not recorded").foregroundStyle(.secondary) }
                                    }.font(.caption2)
                                    if model.manifest?.pages[index].includedInExport == false { Text("Excluded from export").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(8)
                                    .background(index == model.pageIndex ? accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(index == model.pageIndex ? accent : Color.primary.opacity(0.08), lineWidth: index == model.pageIndex ? 2 : 1))
                            }.buttonStyle(.plain).disabled(!model.canNavigate).id(index)
                                .accessibilityLabel("Page \(index + 1), \(model.manifest?.pages[index].selectedTake == nil ? "not recorded" : "recorded")")
                        }
                    }.padding(12)
                }.onChange(of: model.pageIndex) { _, index in withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }.background(.ultraThinMaterial)
    }
    private var canvasToolbar: some View {
        HStack(spacing: 6) {
            ForEach(InkTool.allCases, id: \.self) { tool in
                Button { model.tool = tool } label: {
                    Image(systemName: toolIcon(tool)).font(.system(size: 15)).frame(width: 32, height: 30)
                        .foregroundStyle(model.tool == tool ? accent : Color.primary)
                        .background(model.tool == tool ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(tool.rawValue.capitalized).accessibilityLabel(tool.rawValue.capitalized)
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            Menu {
                ForEach(["blue", "red", "yellow", "green", "purple"], id: \.self) { color in
                    Button(color.capitalized) { model.inkColor = color }
                }
            } label: { Circle().fill(Color(cgColor: SceneRenderer.color(model.inkColor))).frame(width: 15, height: 15) }
                .menuStyle(.borderlessButton).frame(width: 34).help("Ink color")
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }.help("Undo mark (⌘Z)")
            Spacer()
            Button { model.zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Text("\(Int(model.scene.viewport.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 42)
            Button { model.zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button("Fit", action: model.fit).font(.caption)
        }.buttonStyle(.borderless).padding(.horizontal, 14).frame(height: 50).disabled(!model.canDraw)
    }
    private var transport: some View {
        VStack(spacing: 13) {
            if let take = model.selectedTake, model.mode == .idle || model.mode == .playing {
                HStack(spacing: 10) {
                    Text(duration(model.time)).frame(width: 40, alignment: .leading)
                    Slider(value: Binding(get: { min(model.time, take.duration) }, set: { model.seek(to: $0) }), in: 0...max(0.01, take.duration))
                        .accessibilityLabel("Playback position").disabled(model.mode == .exporting)
                    Text(duration(take.duration)).frame(width: 40, alignment: .trailing)
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                if model.mode == .countdown {
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
                    Button { model.play() } label: { Label(model.mode == .playing ? "Pause" : "Play Take", systemImage: model.mode == .playing ? "pause.fill" : "play.fill") }
                        .disabled(model.selectedTake == nil || model.mode == .exporting)
                    Button(action: model.togglePractice) { Label("Practice", systemImage: "timer") }.disabled(model.mode != .idle)
                }
                Spacer()
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<12) { i in Capsule().fill(model.level > Double(i) / 12 ? (i > 9 ? Color.orange : Color.green) : Color.primary.opacity(0.1)).frame(width: 4, height: 5 + CGFloat(i) * 1.1) }
                }.accessibilityLabel("Microphone level \(Int(model.level * 100)) percent")
            }.controlSize(.large)
            HStack {
                Text(model.isRecording ? "This page is locked until you stop recording." : (model.status.isEmpty ? "Each new take keeps your previous recordings." : model.status))
                Spacer()
                Text("⌘⇧R to record")
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(18).background(.bar)
    }
    private var takeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Inspector", selection: $model.showNotes) {
                Text("Takes").tag(false)
                Text("Notes & Timing").tag(true)
            }.pickerStyle(.segmented).padding(12)
            if model.showNotes {
                PresenterNotesView(model: model)
            } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Page \(model.pageIndex + 1) takes").font(.headline)
                Text("Select the take to use in your export.").font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            if model.page?.takes.isEmpty != false {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(accent.opacity(0.7))
                    Text("A fresh page").font(.headline)
                    Text("Press Record Page and explain it your way. You can always try another take.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(22).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(Array((model.page?.takes ?? []).enumerated()), id: \.element.id) { index, take in
                            Button { model.chooseTake(take) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: take.id == model.page?.selectedTakeID ? "checkmark.circle.fill" : "circle").foregroundStyle(take.id == model.page?.selectedTakeID ? accent : Color.secondary)
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack { Text("Take \(index + 1)").font(.callout.weight(.semibold)); Spacer(); Text(duration(take.duration)).font(.caption.monospacedDigit()) }
                                        Text(take.recovered ? "Recovered recording" : take.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                        if take.id == model.page?.selectedTakeID { Text(model.page?.includedInExport == false ? "SELECTED · PAGE EXCLUDED" : "INCLUDED IN EXPORT").font(.system(size: 9, weight: .semibold)).foregroundStyle(accent) }
                                    }
                                }.padding(12).background(take.id == model.page?.selectedTakeID ? accent.opacity(0.08) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(model.mode != .idle)
                                .contextMenu { Button("Delete Take…", role: .destructive) { model.deleteTake(take) }.disabled(model.mode != .idle) }
                        }
                    }.padding(12)
                }
            }
            Spacer(minLength: 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label("Microphone", systemImage: "mic").font(.caption.weight(.semibold))
                Picker("Input", selection: $model.inputID) {
                    Text("System Default").tag("")
                    ForEach(model.inputs, id: \.uniqueID) { input in Text(input.localizedName).tag(input.uniqueID) }
                }.labelsHidden().disabled(model.mode != .idle)
                Button("Refresh inputs", action: model.refreshInputs).font(.caption).buttonStyle(.link).disabled(model.mode != .idle)
                Picker("Countdown", selection: $model.countdownSeconds) {
                    Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5)
                }.font(.caption).disabled(model.mode != .idle)
                Divider()
                HStack { Text("Your presentation").font(.caption.weight(.medium)); Spacer(); Text(duration(model.totalDuration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if model.targetDuration > 0 { Text("Planned time: \(duration(model.targetDuration))").font(.caption2).foregroundStyle(.secondary) }
                RareStepPlayer(model: model)
            }.padding(16)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private var exportConfirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Export your presentation", systemImage: "arrow.up.right.video").font(.title2.weight(.semibold))
            Picker("Format", selection: $model.exportKind) { ForEach(AppModel.ExportKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) } }.pickerStyle(.segmented)
            Text(model.exportKind == .video ? "Selected takes play in page order, including voice and gestures. Private notes stay out of the video." : "Take your presentation with you as an audio file for revision. Only selected, included pages are exported.").foregroundStyle(.secondary)
            let count = model.manifest?.exportTakes.count ?? 0
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("Recorded pages"); Text("\(count)").bold() }
                GridRow { Text("Excluded or unrecorded pages"); Text("\((model.manifest?.pages.count ?? 0) - count)").bold() }
                GridRow { Text("Duration"); Text(duration(model.totalDuration)).monospacedDigit() }
                GridRow { Text("Output"); Text(model.exportKind == .video ? "1080p · 30 fps · MP4" : "AAC audio · M4A") }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack { Button("Cancel") { model.exportSummary = false }; Spacer(); Button("Choose Save Location…") { model.exportSummary = false; model.export() }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 470)
    }
    private var exportProgress: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(accent)
            Text(model.exportKind == .video ? "Making your video" : "Exporting your audio").font(.title2.weight(.semibold))
            Text("Rendering locally on your Mac.").foregroundStyle(.secondary)
            ProgressView(value: model.exportProgress)
            Text("\(Int(model.exportProgress * 100))%").monospacedDigit()
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
        switch tool { case .pointer: return "cursorarrow"; case .pen: return "pencil.tip"; case .highlighter: return "highlighter"; case .eraser: return "eraser"; case .pan: return "hand.draw" }
    }
}

func duration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}
