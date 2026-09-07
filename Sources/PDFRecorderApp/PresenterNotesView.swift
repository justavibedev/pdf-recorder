import SwiftUI
import PDFRecorderCore

@MainActor struct PresenterNotesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var prompter: PresenterPrompterState
    init(model: AppModel) { self.model = model; prompter = model.presenterDisplay.prompter }
    private var recordingHoldsPrompter: Bool { model.mode == .paused || model.mode == .countdown || model.mode == .starting || model.mode == .stopping || model.mode == .exporting }
    var body: some View {
      GeometryReader { container in
       ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            PresenterDisplayControls(model: model, controller: model.presenterDisplay)
            Divider()
            TextField("Page title", text: Binding(get: { model.page?.title ?? "" }, set: { value in model.updatePage { $0.title = value } }))
                .textFieldStyle(.roundedBorder).disabled(model.mode != .idle)
            HStack {
                Label("Presenter notes", systemImage: "text.alignleft").font(.caption.weight(.semibold))
                Spacer()
                Button { model.notesFontSize = max(13, model.notesFontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller notes")
                Button { model.notesFontSize = min(29, model.notesFontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("Larger notes")
            }.buttonStyle(.borderless)
            HStack {
                Toggle("Teleprompter", isOn: $prompter.enabled).toggleStyle(.checkbox)
                Spacer()
                if prompter.enabled {
                    Button(prompter.paused ? "Scroll" : "Hold") { prompter.paused.toggle() }
                        .help("Hold or resume notes scrolling (Shift–Command–Space)")
                        .disabled(recordingHoldsPrompter)
                }
            }.font(.caption)
            if prompter.enabled {
                HStack {
                    Image(systemName: "tortoise")
                    Slider(value: $prompter.speed, in: 8...70).accessibilityLabel("Teleprompter scroll speed")
                    Image(systemName: "hare")
                    Text("\(Int(prompter.speed)) pt/s").monospacedDigit().frame(width: 50, alignment: .trailing)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                if prompter.enabled {
                    GeometryReader { geometry in
                        TeleprompterText(notes: (model.page?.notes ?? "").isEmpty ? "No notes for this page." : model.page!.notes!,
                                         fontSize: model.notesFontSize, speed: prompter.speed,
                                         running: !prompter.paused && !recordingHoldsPrompter, page: model.pageIndex)
                        Rectangle().fill(Color.accentColor.opacity(0.08))
                            .frame(height: model.notesFontSize + 14).offset(y: geometry.size.height * 0.32)
                            .overlay(alignment: .topLeading) {
                                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 3, height: model.notesFontSize + 14)
                                    .offset(y: geometry.size.height * 0.32)
                            }.allowsHitTesting(false).accessibilityHidden(true)
                    }
                } else if model.mode == .idle {
                    TextEditor(text: Binding(get: { model.page?.notes ?? "" }, set: { value in model.updatePage { $0.notes = value } }))
                        .scrollContentBackground(.hidden).accessibilityLabel("Presenter notes for this page")
                } else {
                    ScrollView {
                        Text((model.page?.notes ?? "").isEmpty ? "No notes for this page." : model.page!.notes!)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
            }.font(.system(size: model.notesFontSize)).lineSpacing(5).padding(10)
                .frame(height: max(160, min(360, container.size.height * 0.42)))
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            Text(recordingHoldsPrompter && prompter.enabled ? "Scrolling held · resumes with recording" : model.hasUnsavedMetadata ? "Saving page changes…" : "Private · never included in audio or video")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("Page target").font(.caption)
                Spacer()
                TextField("Seconds", value: Binding(get: { model.page?.targetSeconds ?? 0 }, set: { value in
                    guard value.isFinite else { return }
                    model.updatePage { $0.targetSeconds = min(86_400, max(0, value)) }
                }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 78).accessibilityLabel("Page target in seconds; zero means no target")
                Text("sec").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.mode != .idle)
            HStack {
                Text((model.page?.targetSeconds ?? 0) > 0 ? "Target: \(duration(model.page?.targetSeconds ?? 0))" : "0 seconds = no target").foregroundStyle(.secondary)
                Spacer()
                Button("Rehearsal History") { model.showRehearsalHistory = true }
            }.font(.caption2).buttonStyle(.borderless)
            Toggle("Include page in export", isOn: Binding(get: { model.page?.includedInExport != false }, set: { value in model.updatePage { $0.includedInExport = value } }))
                .font(.caption).disabled(model.mode != .idle)
            HStack {
                Button(action: model.toggleBookmark) { Label(model.page?.bookmarked == true ? "Bookmarked" : "Bookmark", systemImage: model.page?.bookmarked == true ? "bookmark.fill" : "bookmark") }
                    .disabled(model.mode != .idle)
                Spacer()
                Button("Export Notes…", action: model.exportNotes).disabled(model.mode != .idle)
            }.font(.caption).buttonStyle(.borderless)
        }.padding(14)
       }
      }
    }
}

@MainActor struct PaceIndicator: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let target = model.page?.targetSeconds, target > 0 {
            let elapsed = model.mode == .idle ? (model.selectedTake?.duration ?? 0) : model.time
            HStack(spacing: 8) {
                Image(systemName: elapsed > target ? "clock.badge.exclamationmark" : "timer")
                Text(elapsed > target ? "\(duration(elapsed - target)) over target" : "\(duration(max(0, target - elapsed))) to target")
                ProgressView(value: min(1, elapsed / target)).frame(width: 55)
            }.font(.caption).foregroundStyle(elapsed > target ? Color.orange : Color.secondary)
                .accessibilityLabel("Page time \(duration(elapsed)), target \(duration(target))")
        }
    }
}
