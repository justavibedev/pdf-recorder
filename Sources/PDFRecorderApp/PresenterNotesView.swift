import SwiftUI
import PDFRecorderCore

@MainActor struct PresenterNotesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var prompter: PresenterPrompterState
    @State private var pageOptions = false
    @State private var presenting = false
    init(model: AppModel) { self.model = model; prompter = model.presenterDisplay.prompter }
    private var recordingHoldsPrompter: Bool { model.mode == .paused || model.mode == .countdown || model.mode == .starting || model.mode == .stopping || model.mode == .exporting }
    var body: some View {
        GeometryReader { container in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Page title", text: Binding(get: { model.page?.title ?? "" }, set: { value in model.updatePage { $0.title = value } }))
                        .textFieldStyle(.plain).font(.system(size: 14, weight: .medium)).disabled(model.mode != .idle)
                    HStack {
                        Text("PRIVATE NOTES").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(StudioTheme.faint)
                        Spacer()
                        Button { model.notesFontSize = max(13, model.notesFontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller notes").accessibilityLabel("Smaller notes")
                        Button { model.notesFontSize = min(29, model.notesFontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("Larger notes").accessibilityLabel("Larger notes")
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(StudioTheme.muted)
                    Group {
                        if prompter.enabled {
                            GeometryReader { geometry in
                                TeleprompterText(notes: (model.page?.notes ?? "").isEmpty ? "No notes for this page." : model.page!.notes!,
                                                 fontSize: model.notesFontSize, speed: prompter.speed,
                                                 running: !prompter.paused && !recordingHoldsPrompter, page: model.pageIndex)
                                Rectangle().fill(Color.white.opacity(0.04)).frame(height: model.notesFontSize + 14).offset(y: geometry.size.height * 0.32)
                                    .overlay(alignment: .topLeading) {
                                        Rectangle().fill(Color.white.opacity(0.4)).frame(width: 2, height: model.notesFontSize + 14).offset(y: geometry.size.height * 0.32)
                                    }.allowsHitTesting(false).accessibilityHidden(true)
                            }
                        } else if model.mode == .idle {
                            TextEditor(text: Binding(get: { model.page?.notes ?? "" }, set: { value in model.updatePage { $0.notes = value } }))
                                .scrollContentBackground(.hidden).accessibilityLabel("Presenter notes for this page")
                        } else {
                            ScrollView { Text((model.page?.notes ?? "").isEmpty ? "No notes for this page." : model.page!.notes!).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        }
                    }.font(.system(size: model.notesFontSize)).lineSpacing(5).padding(8)
                        .frame(height: max(190, min(380, container.size.height * 0.5))).studioPanel(cornerRadius: 6)
                    Text(recordingHoldsPrompter && prompter.enabled ? "Scrolling resumes with recording" : model.hasUnsavedMetadata ? "Saving changes…" : "Only you see these. Never included in exports.")
                        .font(.system(size: 10)).foregroundStyle(StudioTheme.faint)
                    DisclosureGroup("Teleprompter", isExpanded: $prompter.enabled) {
                        VStack(spacing: 10) {
                            HStack {
                                Text("Auto-scroll").foregroundStyle(StudioTheme.muted)
                                Spacer()
                                Button(prompter.paused ? "Scroll" : "Hold") { prompter.paused.toggle() }
                                    .help("Hold or resume scrolling (Shift–Command–Space)").disabled(recordingHoldsPrompter)
                            }
                            HStack {
                                Image(systemName: "tortoise")
                                Slider(value: $prompter.speed, in: 8...70).accessibilityLabel("Teleprompter scroll speed")
                                Image(systemName: "hare")
                                Text("\(Int(prompter.speed)) pt/s").monospacedDigit()
                            }.font(.system(size: 10)).foregroundStyle(StudioTheme.muted)
                        }.padding(.top, 10)
                    }.font(.system(size: 12, weight: .medium))
                    DisclosureGroup("Page options", isExpanded: $pageOptions) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Time target"); Spacer()
                                TextField("Seconds", value: Binding(get: { model.page?.targetSeconds ?? 0 }, set: { value in
                                    guard value.isFinite else { return }; model.updatePage { $0.targetSeconds = min(86_400, max(0, value)) }
                                }), format: .number.precision(.fractionLength(0...1)))
                                    .textFieldStyle(.roundedBorder).frame(width: 65).accessibilityLabel("Page target in seconds; zero means no target")
                                Text("sec").foregroundStyle(StudioTheme.faint)
                            }.disabled(model.mode != .idle)
                            Text((model.page?.targetSeconds ?? 0) > 0 ? "Target: \(duration(model.page?.targetSeconds ?? 0))" : "0 seconds = no target").foregroundStyle(StudioTheme.faint)
                            Toggle("Include page in export", isOn: Binding(get: { model.page?.includedInExport != false }, set: { value in model.updatePage { $0.includedInExport = value } })).disabled(model.mode != .idle)
                            HStack {
                                Button(action: model.toggleBookmark) { Label(model.page?.bookmarked == true ? "Bookmarked" : "Bookmark", systemImage: model.page?.bookmarked == true ? "bookmark.fill" : "bookmark") }.disabled(model.mode != .idle)
                                Spacer()
                                Button("Export Notes…", action: model.exportNotes).disabled(model.mode != .idle)
                            }.buttonStyle(.borderless)
                        }.font(.system(size: 11)).padding(.top, 10)
                    }.font(.system(size: 12, weight: .medium))
                    DisclosureGroup("Presenting", isExpanded: $presenting) {
                        VStack(alignment: .leading, spacing: 10) {
                            PresenterDisplayControls(model: model, controller: model.presenterDisplay)
                            Button("Rehearsal Reports…") { model.showRehearsalHistory = true }.buttonStyle(.borderless)
                        }.font(.system(size: 11)).padding(.top, 10)
                    }.font(.system(size: 12, weight: .medium))
                }.padding(14)
            }
        }.onAppear { presenting = model.presenterDisplay.visible }
            .onChange(of: model.presenterDisplay.visible) { _, visible in if visible { presenting = true } }
            .onChange(of: model.mode) { _, mode in if mode == .rehearsing { presenting = true } }
    }
}

@MainActor struct PaceIndicator: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let target = model.page?.targetSeconds, target > 0 {
            let reviewing = model.mode == .playing || model.mode == .loadingPlayback || model.playbackPaused
            let phase: PresentationPace.Phase = reviewing ? .playback : model.mode == .idle ? .takeSummary : .live
            let sceneTime = model.mode == .countdown || model.mode == .starting ? 0 : model.time
            let elapsed = PresentationPace.elapsed(take: model.selectedTake, sourceTime: sceneTime, phase: phase)
            HStack(spacing: 8) {
                Image(systemName: elapsed > target ? "clock.badge.exclamationmark" : "timer")
                Text(elapsed > target ? "\(duration(elapsed - target)) over target" : "\(duration(max(0, target - elapsed))) to target")
                ProgressView(value: min(1, elapsed / target)).frame(width: 55)
            }.font(.caption).foregroundStyle(elapsed > target ? Color.orange : Color.secondary)
                .accessibilityLabel("Page time \(duration(elapsed)), target \(duration(target))")
        }
    }
}
