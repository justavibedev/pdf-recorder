import SwiftUI
import PDFRecorderCore

@MainActor struct RecentProjectsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 310))], spacing: 14) {
                ForEach(model.recentProjects) { project in
                    VStack(alignment: .leading, spacing: 10) {
                        Button { model.open(URL(fileURLWithPath: project.path)) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                                    if let preview = project.previewName, let image = NSImage(contentsOf: model.supportRoot.appendingPathComponent(preview)) {
                                        Image(nsImage: image).resizable().scaledToFit().padding(5)
                                    } else { Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.secondary) }
                                }.frame(height: 108)
                                Text(project.title).font(.headline).lineLimit(1)
                                Text("\(project.recordedCount) of \(project.pageCount) pages recorded · Resume page \(project.workspace.page + 1)").font(.caption).foregroundStyle(.secondary)
                                ProgressView(value: Double(project.recordedCount), total: Double(max(1, project.pageCount)))
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Open \(project.title), \(project.recordedCount) of \(project.pageCount) pages recorded")
                        HStack {
                            Text(project.lastOpened.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button { model.togglePin(project) } label: { Image(systemName: project.pinned ? "pin.fill" : "pin") }.help(project.pinned ? "Unpin project" : "Pin project")
                            Menu { Button("Remove from Recents") { model.forgetRecent(project) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                        }.buttonStyle(.borderless)
                    }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(4)
        }.frame(maxHeight: 310)
    }
}

@MainActor struct RecordingSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Recording & audio") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Microphone", selection: $model.inputID) {
                        Text("System Default").tag("")
                        ForEach(model.inputs, id: \.uniqueID) { input in Text(input.localizedName).tag(input.uniqueID) }
                    }.disabled(model.mode != .idle)
                    HStack {
                        Button("Refresh", action: model.refreshInputs)
                        Spacer()
                        Button("Check Microphone", action: model.startMicrophoneCheck).help("Starts the microphone only when clicked. No audio is saved.")
                    }.disabled(model.mode != .idle)
                    Picker("Countdown", selection: $model.countdownSeconds) { Text("Off").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5) }.disabled(model.mode != .idle)
                    Toggle("Match volume between pages", isOn: Binding(get: { model.manifest?.matchLoudness == true }, set: { model.setMatchLoudness($0) })).disabled(model.mode != .idle)
                    Text("Playback and exports use the same volume adjustments. Original audio stays intact.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.caption)
            HStack { Text("Presentation").font(.caption.weight(.medium)); Spacer(); Text(duration(model.totalDuration)).font(.caption.monospacedDigit()) }
            if model.targetDuration > 0 { Text("Planned: \(duration(model.targetDuration))").font(.caption2).foregroundStyle(.secondary) }
            RareStepPlayer(model: model)
        }.padding(14)
    }
}

@MainActor struct ExportSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export your presentation").font(.title2.weight(.semibold))
            Picker("Format", selection: $model.exportKind) { ForEach(AppModel.ExportKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Picker("Pages", selection: $model.exportScope) { ForEach(ExportScope.allCases) { Text($0.rawValue).tag($0) } }
            if model.exportScope == .range { TextField("For example: 1, 3-5", text: $model.exportRange).textFieldStyle(.roundedBorder) }
            if model.exportScope == .chapter { Text("Uses the nearest heading in the PDF outline. Without an outline, the entire document is one chapter.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Separate file for every page", isOn: $model.exportSeparately)
            if model.exportKind == .video { Picker("Quality", selection: $model.exportPreset) { ForEach(ExportPreset.allCases) { Text($0.label).tag($0) } } }
            let included = (try? model.exportSelection().count) ?? 0
            let requested = (try? model.requestedExportPages().count) ?? 0
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                GridRow { Text("Included / skipped"); Text("\(included) / \(model.exportScope == .included ? (model.manifest?.pages.count ?? 0) - included : requested - included)").bold() }
                GridRow { Text("Trimmed duration"); Text(duration(model.exportSelectedDuration)).monospacedDigit() }
                GridRow { Text("Estimated size"); Text(ByteCountFormatter.string(fromByteCount: model.exportOptions.estimatedBytes(duration: model.exportSelectedDuration, audioOnly: model.exportKind == .audio), countStyle: .file)) }
                if model.exportKind == .video { GridRow { Text("Output"); Text("\(model.exportPreset.width)×\(model.exportPreset.height) · 30 fps") } }
            }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            if included == 0 { Text("Choose a valid range with at least one recorded page.").foregroundStyle(.orange).font(.caption) }
            Text("Selected takes stay in PDF order. Page-range exports do not change your saved page choices. Notes and search highlights stay private. File size is an estimate.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { model.exportSummary = false }; Spacer(); Button("Choose Location…") { model.exportSummary = false; model.export() }.buttonStyle(.borderedProminent).disabled(included == 0) }
        }.padding(24).frame(width: 480)
    }
}
