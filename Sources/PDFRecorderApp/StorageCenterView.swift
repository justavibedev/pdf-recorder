import SwiftUI
import PDFRecorderCore

@MainActor struct StorageCenterView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var restoreCandidate: ProjectSnapshot?
    @State private var deleteCandidate: ProjectSnapshot?
    private var unusedTakes: [(page: Int, take: Take)] {
        guard let manifest = model.manifest else { return [] }
        return manifest.pages.enumerated().flatMap { index, page in
            page.takes.filter { $0.id != page.selectedTakeID }.map { (index, $0) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage & Recovery").font(.title2.bold())
                    Text(model.manifest?.title ?? "Project").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refreshStorage) { Image(systemName: "arrow.clockwise") }.help("Refresh storage inventory")
                    .accessibilityLabel("Refresh storage inventory")
                    .disabled(model.storageLoading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.storageLoading { ProgressView("Checking project files…").controlSize(.small) }
            if let inventory = model.storageInventory {
                HStack(spacing: 12) {
                    metric("Project", bytes: inventory.totalBytes, symbol: "doc.zipper")
                    metric("Available space", bytes: inventory.availableBytes, symbol: "internaldrive")
                    metric("Unused takes", bytes: inventory.unusedTakeBytes, symbol: "waveform")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if inventory.hasActiveTake {
                            GroupBox {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "arrow.counterclockwise.circle.fill").font(.title2).foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("An interrupted recording can be recovered").font(.headline)
                                        Text("Restore readable audio and saved gestures as another take. Existing takes stay available.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 6)
                                    Button("Recover Take", action: model.recoverActiveTake).disabled(model.mode != .idle)
                                }.padding(6)
                            }
                        }
                        if !inventory.setAsideRecordings.isEmpty {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Recordings kept for later (\(inventory.setAsideRecordings.count))").font(.headline)
                                    Text(inventory.hasActiveTake ? "Recover the interrupted take above first. Then these saved recording journals can be recovered one at a time." : "These interrupted recordings were kept aside. Recover readable audio and saved gestures without replacing completed takes.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(inventory.setAsideRecordings, id: \.self) { name in
                                        HStack {
                                            Label(name, systemImage: "waveform.badge.plus").font(.caption).lineLimit(2)
                                            Spacer()
                                            Button("Recover") { model.recoverSetAside(name) }
                                                .disabled(inventory.hasActiveTake || model.mode != .idle)
                                        }
                                    }
                                }.padding(6)
                            }
                        }
                        if !inventory.unavailable.isEmpty {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Unavailable recordings (\(inventory.unavailable.count))").font(.headline)
                                        Spacer()
                                        Button("Retry Restored Files", action: model.retryUnavailableTakes).disabled(model.mode != .idle)
                                    }
                                    Text("These take details are preserved while their files are missing. Return the files to the project, then retry.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(inventory.unavailable) { item in
                                        VStack(alignment: .leading, spacing: 4) {
                                            takeLabel(item.take, page: item.page)
                                            DisclosureGroup("Expected files in this project") {
                                                Text(item.take.audioPath + "\n" + item.take.eventsPath)
                                                    .font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                            }.font(.caption)
                                        }
                                    }
                                }.padding(6)
                            }
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Snapshots (\(inventory.snapshots.count))").font(.headline)
                                    Spacer()
                                    Button("Save Snapshot", action: model.makeSnapshot).disabled(model.mode != .idle)
                                }
                                Text("Snapshots preserve take choices, trims, page notes, and settings. Recording files stay shared, so checkpoints use little space.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if inventory.snapshots.isEmpty { empty("No snapshots yet. Save one before making a large change.") }
                                ForEach(inventory.snapshots) { snapshot in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(snapshot.reason).font(.callout)
                                            Text(snapshot.date.formatted(date: .abbreviated, time: .shortened) + " · \(snapshot.manifest.selectedTakes.count) recorded pages")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Restore") { restoreCandidate = snapshot }.disabled(model.mode != .idle)
                                        Button { deleteCandidate = snapshot } label: { Image(systemName: "trash") }
                                            .help("Remove this snapshot").accessibilityLabel("Remove snapshot \(snapshot.reason)").disabled(model.mode != .idle)
                                    }
                                }
                            }.padding(6)
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Take trash (\(inventory.trash.count))").font(.headline)
                                Text("Deleted takes can be restored until you explicitly delete them permanently. Takes used by a snapshot are protected.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if inventory.trash.isEmpty { empty("Trash is empty.") }
                                ForEach(inventory.trash) { item in
                                    HStack(spacing: 12) {
                                        takeLabel(item.take, page: item.page)
                                        Spacer()
                                        Button("Restore") { model.restoreDeletedTake(item.id) }.disabled(model.mode != .idle)
                                        Button { model.purgeDeletedTake(item) } label: { Image(systemName: "trash.slash") }
                                            .help("Delete take permanently").accessibilityLabel("Permanently delete \(item.take.displayName) from page \(item.page + 1)").disabled(model.mode != .idle)
                                    }
                                }
                            }.padding(6)
                        }
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Unused takes (\(unusedTakes.count))").font(.headline)
                                Text("These takes are kept in your history but are not selected for export. Review them before choosing what to keep.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if unusedTakes.isEmpty { empty("Every saved take is selected for its page.") }
                                ForEach(unusedTakes, id: \.take.id) { item in
                                    HStack(spacing: 12) {
                                        takeLabel(item.take, page: item.page)
                                        Spacer()
                                        Button("Review") {
                                            model.navigate(to: item.page); model.chooseTake(item.take)
                                            model.hideInspector = false; model.showNotes = false; dismiss()
                                        }.disabled(model.mode != .idle)
                                    }
                                }
                            }.padding(6)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.storageLoading {
                ContentUnavailableView("Storage details unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text("Use Refresh to retry. Your project remains open."))
            }
            HStack {
                Text("Nothing is cleaned up automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Project in Finder", action: model.revealProject)
            }
        }.padding(22).frame(minWidth: 620, idealWidth: 740, minHeight: 470, idealHeight: 660)
            .alert("Restore this snapshot?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })) {
                Button("Cancel", role: .cancel) { restoreCandidate = nil }
                Button("Restore Snapshot") {
                    if let candidate = restoreCandidate { model.restoreSnapshot(candidate) }
                    restoreCandidate = nil
                }
            } message: {
                Text("A new snapshot of your current work is saved first. Newer takes stay recoverable in Trash. Page notes and take selections return to this checkpoint.")
            }
            .alert("Remove this snapshot?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
                Button("Remove Snapshot", role: .destructive) {
                    if let candidate = deleteCandidate { model.removeSnapshot(candidate) }
                    deleteCandidate = nil
                }
            } message: { Text("This checkpoint will no longer be restorable. Your current project and recording files remain available.") }
    }
    private func metric(_ label: String, bytes: Int64, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    private func takeLabel(_ take: Take, page: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Page \(page + 1) · \(take.displayName)").font(.callout)
            Text(duration(take.playbackDuration) + " · " + take.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func empty(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).padding(.vertical, 5) }
}
