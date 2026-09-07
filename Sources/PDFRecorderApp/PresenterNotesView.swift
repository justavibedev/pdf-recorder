import SwiftUI
import PDFRecorderCore

@MainActor struct PresenterNotesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Page title", text: Binding(get: { model.page?.title ?? "" }, set: { value in model.updatePage { $0.title = value } }))
                .textFieldStyle(.roundedBorder).disabled(model.mode != .idle)
            HStack {
                Label("Presenter notes", systemImage: "text.alignleft").font(.caption.weight(.semibold))
                Spacer()
                Button { model.notesFontSize = max(13, model.notesFontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.help("Smaller notes")
                Button { model.notesFontSize = min(29, model.notesFontSize + 2) } label: { Image(systemName: "textformat.size.larger") }.help("Larger notes")
            }.buttonStyle(.borderless)
            Group {
                if model.mode == .idle {
                    TextEditor(text: Binding(get: { model.page?.notes ?? "" }, set: { value in model.updatePage { $0.notes = value } }))
                        .scrollContentBackground(.hidden).accessibilityLabel("Presenter notes for this page")
                } else {
                    ScrollView {
                        Text((model.page?.notes ?? "").isEmpty ? "No notes for this page." : model.page!.notes!)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
            }.font(.system(size: model.notesFontSize)).lineSpacing(5).padding(10)
                .frame(minHeight: 130, maxHeight: .infinity)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            Text(model.hasUnsavedMetadata ? "Saving page changes…" : "Private · never included in audio or video")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("Page target", selection: Binding(get: { Int(model.page?.targetSeconds ?? 0) }, set: { value in model.updatePage { $0.targetSeconds = Double(value) } })) {
                Text("No target").tag(0)
                ForEach([30, 60, 90, 120, 180, 300, 600], id: \.self) { value in Text(duration(Double(value))).tag(value) }
            }.font(.caption).disabled(model.mode != .idle)
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
