import SwiftUI
import PDFRecorderCore

/// Auditioning a card never changes the take chosen for export.
@MainActor struct TakeBrowserView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page \(model.pageIndex + 1) takes").font(.headline)
                    Text("Listen freely. Choose which take to export.").font(.caption).foregroundStyle(.secondary)
                }
                if model.page?.takes.isEmpty != false {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(Color.accentColor)
                        Text("A fresh page").font(.headline)
                        Text("Record your explanation, then compare takes and polish the best one here.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(.vertical, 25).frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(Array((model.page?.takes ?? []).enumerated()), id: \.element.id) { index, take in
                            card(take, number: index + 1)
                        }
                    }
                    if let take = model.selectedTake {
                        Divider()
                        TakeEditorView(model: model, take: take).id(take.id)
                    }
                }
                if let deletedID = model.lastDeletedTake {
                    Button("Undo Delete", systemImage: "arrow.uturn.backward") { model.restoreDeletedTake(deletedID) }
                        .font(.caption).disabled(model.mode != .idle)
                }
            }.padding(14)
        }
    }
    private func card(_ take: Take, number: Int) -> some View {
        let previewing = take.id == model.selectedTakeID
        let exporting = take.id == model.page?.selectedTakeID
        return VStack(alignment: .leading, spacing: 9) {
            Button { model.chooseTake(take) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: previewing ? "headphones.circle.fill" : "waveform.circle")
                        .font(.title3).foregroundStyle(previewing ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(take.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? take.displayName : "Take \(number)")
                                .font(.callout.weight(.semibold)).lineLimit(2)
                            if take.favorite == true { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
                            Spacer(minLength: 0)
                            Text(duration(take.playbackDuration)).font(.caption.monospacedDigit())
                        }
                        HStack(spacing: 5) {
                            if take.recovered { Text("Recovered") }
                            else { Text(take.createdAt, format: .dateTime.hour().minute()) }
                            Text("·")
                            Text((take.reviewStatus ?? .unreviewed).label)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.mode != .idle && model.mode != .playing)
                .accessibilityLabel("Preview \(take.displayName), \(duration(take.playbackDuration)), \(exporting ? "chosen for export" : "not chosen for export")")
            HStack(spacing: 7) {
                Button {
                    if model.selectedTakeID == take.id && model.mode == .playing { model.play() }
                    else { model.chooseTake(take); model.play() }
                } label: {
                    Label(previewing && model.mode == .playing ? "Pause" : "Listen", systemImage: previewing && model.mode == .playing ? "pause.fill" : "play.fill")
                }.disabled(model.mode != .idle && model.mode != .playing)
                Spacer(minLength: 0)
                if exporting {
                    Label(model.page?.includedInExport == false ? "Chosen · excluded" : "Export take", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                } else {
                    Button("Use in Export") { model.useTake(take) }.disabled(model.mode != .idle)
                }
            }.font(.caption).buttonStyle(.borderless)
        }.padding(11)
            .background(previewing ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(previewing ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06)))
            .contextMenu {
                Button("Use in Export") { model.useTake(take) }.disabled(model.mode != .idle)
                Button("Compare with Current Take") { model.comparisonTakeID = take.id }.disabled(previewing)
                Divider()
                Button("Move to Trash", role: .destructive) { model.deleteTake(take) }.disabled(model.mode != .idle)
            }
    }
}

@MainActor private struct TakeEditorView: View {
    @ObservedObject var model: AppModel
    let take: Take
    @State private var name: String
    @State private var trimStart: Double
    @State private var trimEnd: Double
    @State private var gain: Double
    @State private var markerLabel = ""
    @State private var showTrimming = false
    @State private var showVolume = false
    @State private var showReview = true
    init(model: AppModel, take: Take) {
        self.model = model; self.take = take
        _name = State(initialValue: take.name ?? "")
        _trimStart = State(initialValue: take.playbackStart)
        _trimEnd = State(initialValue: take.playbackEnd)
        _gain = State(initialValue: take.gainDB ?? 0)
    }
    private var editable: Bool { model.mode == .idle }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Previewing this take", systemImage: "headphones").font(.caption.weight(.semibold))
                Spacer()
                Button { model.updateTake { $0.favorite = $0.favorite != true } } label: {
                    Image(systemName: take.favorite == true ? "star.fill" : "star").foregroundStyle(take.favorite == true ? Color.orange : Color.secondary)
                }.buttonStyle(.borderless).help("Favorite take").accessibilityLabel(take.favorite == true ? "Remove favorite" : "Favorite take").disabled(!editable)
            }
            HStack(spacing: 6) {
                TextField("Name this take", text: $name).textFieldStyle(.roundedBorder).onSubmit(saveName)
                Button(action: saveName) { Image(systemName: "checkmark") }.help("Save take name").accessibilityLabel("Save take name")
            }.disabled(!editable)
            Picker("Review", selection: Binding(get: { take.reviewStatus ?? .unreviewed }, set: { value in model.updateTake { $0.reviewStatus = value } })) {
                ForEach(TakeReviewStatus.allCases) { status in Text(status.label).tag(status) }
            }.font(.caption).disabled(!editable)
            comparison
            DisclosureGroup("Trim beginning & end", isExpanded: $showTrimming) { trimming.padding(.top, 8) }.font(.callout.weight(.medium))
            DisclosureGroup("Volume & matching", isExpanded: $showVolume) { volume.padding(.top, 8) }.font(.callout.weight(.medium))
            DisclosureGroup("Loops & review markers", isExpanded: $showReview) { review.padding(.top, 8) }.font(.callout.weight(.medium))
            Button("Move Take to Trash", systemImage: "trash", role: .destructive) { model.deleteTake(take) }
                .font(.caption).buttonStyle(.borderless).disabled(!editable)
        }.onChange(of: take) { _, value in
            trimStart = value.playbackStart; trimEnd = value.playbackEnd; gain = value.gainDB ?? 0
        }
    }
    private func saveName() { model.updateTake { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }
    private var comparison: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Compare", selection: $model.comparisonTakeID) {
                Text("Choose another take").tag(Optional<UUID>.none)
                ForEach((model.page?.takes ?? []).filter { $0.id != take.id }) { other in
                    Text("\(comparisonName(other)) · \(duration(other.playbackDuration))").tag(Optional(other.id))
                }
            }.font(.caption)
            if model.comparisonTakeID != nil {
                Button("Switch A / B at this position", systemImage: "arrow.left.arrow.right", action: model.compareTake)
                    .font(.caption).disabled(model.mode != .idle && model.mode != .playing)
            }
        }.disabled(model.mode != .idle && model.mode != .playing)
    }
    private func comparisonName(_ other: Take) -> String {
        if other.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return other.displayName }
        return "Take \((model.page?.takes.firstIndex { $0.id == other.id } ?? 0) + 1)"
    }
    private var trimming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Original: \(duration(take.duration)) · kept: \(duration(max(0, trimEnd - trimStart)))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            trimField("Start", value: $trimStart)
            Slider(value: $trimStart, in: 0...max(0.001, trimEnd - 0.05)).accessibilityLabel("Trim start in seconds")
            trimField("End", value: $trimEnd)
            Slider(value: $trimEnd, in: min(take.duration - 0.001, trimStart + 0.05)...max(0.05, take.duration)).accessibilityLabel("Trim end in seconds")
            HStack {
                Button("Start Here") { trimStart = max(0, min(model.time, trimEnd - 0.05)) }
                Button("End Here") { trimEnd = min(take.duration, max(model.time, trimStart + 0.05)) }
            }.font(.caption)
            HStack {
                Button("Reset") { trimStart = 0; trimEnd = take.duration; model.updateTake { $0.trimStart = nil; $0.trimEnd = nil } }
                Spacer()
                Button("Apply Trim") {
                    let start = max(0, min(trimStart, take.duration)), end = max(0, min(trimEnd, take.duration))
                    model.updateTake { value in
                        value.trimStart = start; value.trimEnd = end
                        if let loop = value.loopRange, loop.start < start || loop.end > end { value.loopRange = nil }
                    }
                }.buttonStyle(.borderedProminent).disabled(trimEnd - trimStart < 0.05)
            }.font(.caption)
            Text("The source stays intact. Playback and exports use the kept range.").font(.caption2).foregroundStyle(.secondary)
        }.fontWeight(.regular).disabled(!editable)
    }
    private func trimField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).frame(width: 80).accessibilityLabel("\(label) time in seconds")
            Text("sec").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var volume: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("Take volume"); Spacer(); Text("\(gain, specifier: "%+.0f") dB").monospacedDigit() }.font(.caption)
            Slider(value: $gain, in: -24...12, step: 1) { editing in if !editing { model.updateTake { $0.gainDB = gain } } }
                .accessibilityLabel("Take volume in decibels")
            Toggle("Match speech levels between pages", isOn: Binding(get: { model.manifest?.matchLoudness == true }, set: { model.setMatchLoudness($0) }))
                .font(.caption)
            Text("Playback and exports apply volume changes and short edge fades. Original audio is preserved.").font(.caption2).foregroundStyle(.secondary)
        }.fontWeight(.regular).disabled(!editable)
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Loop A–B", isOn: $model.loopEnabled).disabled(take.loopRange == nil)
                Spacer(minLength: 2)
                if take.loopRange != nil {
                    Button("Clear") { model.loopEnabled = false; model.updateTake { $0.loopRange = nil } }.disabled(!editable)
                }
            }.font(.caption)
            if let loop = take.loopRange {
                Text("A \(duration(loop.start))  →  B \(duration(loop.end))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Set A Here") {
                    let start = min(model.time, take.playbackEnd - 0.05)
                    model.updateTake { $0.loopRange = .init(start: start, end: max(start + 0.05, take.loopRange?.end ?? take.playbackEnd)) }
                }
                Button("Set B Here") {
                    let end = max(model.time, take.playbackStart + 0.05)
                    model.updateTake { $0.loopRange = .init(start: min(end - 0.05, take.loopRange?.start ?? take.playbackStart), end: end) }
                }
            }.font(.caption).disabled(!editable)
            HStack(spacing: 6) {
                TextField("Marker at \(duration(model.time))", text: $markerLabel).textFieldStyle(.roundedBorder).onSubmit(addMarker)
                Button(action: addMarker) { Image(systemName: "plus") }.help("Add marker at playhead").accessibilityLabel("Add review marker")
                    .disabled(markerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(!editable)
            ForEach(take.reviewMarkers ?? []) { marker in
                HStack(alignment: .top) {
                    Button { model.seek(to: marker.time) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text(duration(marker.time)).monospacedDigit().foregroundStyle(Color.accentColor)
                            Text(marker.label).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        }
                    }.buttonStyle(.plain).disabled(model.mode != .idle && model.mode != .playing)
                    Spacer(minLength: 1)
                    Button { model.updateTake { $0.reviewMarkers?.removeAll { $0.id == marker.id } } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Remove marker").accessibilityLabel("Remove marker: \(marker.label)").disabled(!editable)
                }.font(.caption)
            }
        }.fontWeight(.regular)
    }
    private func addMarker() { model.addReviewMarker(markerLabel); markerLabel = "" }
}
