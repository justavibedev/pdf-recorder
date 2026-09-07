import SwiftUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import PDFRecorderCore

extension UTType { static let pdfRecorder = UTType(exportedAs: "org.pdfrecorder.project", conformingTo: .package) }

@MainActor final class AppModel: ObservableObject {
    enum Mode { case idle, starting, recording, paused, stopping, playing, exporting }
    @Published var manifest: ProjectManifest?
    @Published var pdf: PDFDocument?
    @Published var projectURL: URL?
    @Published var pageIndex = 0
    @Published var artwork: PageArtwork?
    @Published var scene = Scene()
    @Published var mode = Mode.idle { didSet { updateTimer() } }
    @Published var tool = InkTool.pointer
    @Published var inkColor = "blue"
    @Published var time = 0.0
    @Published var level = 0.0
    @Published var errorMessage: String?
    @Published var status = ""
    @Published var inputID = ""
    @Published var inputs: [AVCaptureDevice] = []
    @Published var exportProgress = 0.0
    @Published var exportSummary = false
    @Published var recoveryProjects: [URL] = []
    @Published var showRecovery = false
    @Published var selectedTakeID: UUID?
    private let microphone = MicrophoneRecorder()
    private var activeTake: Take?
    private var events: [TimedEvent] = []
    private var undoActions: [SceneAction] = []
    private var player: AVAudioPlayer?
    private var timeline: Timeline?
    private var playbackQueue: [(page: Int, take: Take)] = []
    private var timer: Timer?
    private var lastJournal = 0.0
    private var journalEventIndex = 0
    private var exportTask: Task<Void, Never>?
    private var password: String?
    private var thumbnailCache = NSCache<NSNumber, NSImage>()
    private var artworkCache = NSCache<NSNumber, ArtworkBox>()
    private class ArtworkBox { let value: PageArtwork; init(_ value: PageArtwork) { self.value = value } }
    var page: PageRecord? { guard let manifest, manifest.pages.indices.contains(pageIndex) else { return nil }; return manifest.pages[pageIndex] }
    var selectedTake: Take? { page?.takes.first { $0.id == selectedTakeID } }
    var canNavigate: Bool { mode == .idle || mode == .playing }
    var canDraw: Bool { artwork != nil && (mode == .idle || mode == .recording) }
    var isRecording: Bool { mode == .recording || mode == .paused || mode == .starting || mode == .stopping }
    var totalDuration: Double { manifest?.selectedTakes.reduce(0) { $0 + $1.take.duration } ?? 0 }
    var recoveryRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Recorder/Recovery", isDirectory: true)
    }
    var isRecoveryProject: Bool { projectURL?.path.hasPrefix(recoveryRoot.path + "/") ?? false }

    init() {
        artworkCache.totalCostLimit = 100 * 1024 * 1024
        thumbnailCache.countLimit = 100
        refreshInputs()
        microphone.onFailure = { [weak self] message in
            guard let self, self.mode == .recording || self.mode == .paused else { return }
            Task { await self.stopRecording(); self.errorMessage = message }
        }
        discoverRecovery()
    }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard mode == .recording || mode == .playing else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func refreshInputs() { inputs = MicrophoneRecorder.devices }
    func discoverRecovery() {
        recoveryProjects = ((try? FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "pdfrecorder" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        showRecovery = !recoveryProjects.isEmpty
    }
    func thumbnail(_ index: Int) -> NSImage? {
        let key = NSNumber(value: index)
        if let image = thumbnailCache.object(forKey: key) { return image }
        guard let page = pdf?.page(at: index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 220, height: 140), for: .cropBox)
        thumbnailCache.setObject(image, forKey: key)
        return image
    }
    func openPanel() {
        guard mode == .idle else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf, .pdfRecorder]; panel.canChooseDirectories = false
        panel.message = "Open a PDF or continue a PDF Recorder project."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    private func unlock(_ document: PDFDocument) -> String? {
        guard document.isLocked else { return nil }
        let alert = NSAlert(); alert.messageText = "Unlock PDF"; alert.informativeText = "Enter the PDF password. It is only kept in memory while this project is open."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field; alert.addButton(withTitle: "Unlock"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard document.unlock(withPassword: field.stringValue) else { errorMessage = "That password did not unlock the PDF."; return nil }
        return field.stringValue
    }
    func open(_ url: URL) {
        guard mode == .idle else { return }
        do {
            let root: URL
            var newManifest: ProjectManifest
            let document: PDFDocument
            var newPassword: String?
            if url.pathExtension.lowercased() == "pdfrecorder" {
                root = url; newManifest = try ProjectStore.load(at: root)
                guard let loaded = PDFDocument(url: try ProjectStore.location(newManifest.sourcePDF, in: root)) else { throw RecorderError.message("The source PDF is missing or corrupt.") }
                newPassword = unlock(loaded)
                guard !loaded.isLocked else { return }
                guard loaded.pageCount == newManifest.pages.count else { throw RecorderError.message("The source PDF page count does not match this project.") }
                document = loaded
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("active-take.json").path) {
                    let alert = NSAlert(); alert.messageText = "Recover interrupted take?"
                    alert.informativeText = "PDF Recorder found an unfinished recording. Recover its readable audio and saved gestures as a new take."
                    alert.addButton(withTitle: "Recover Take"); alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        do { newManifest = try ProjectStore.recover(at: root, manifest: newManifest) }
                        catch { errorMessage = "The unfinished take could not be recovered: \(error.localizedDescription). Its files have been kept." }
                    }
                }
            } else {
                guard let loaded = PDFDocument(url: url) else { throw RecorderError.message("This file is not a readable PDF.") }
                newPassword = unlock(loaded)
                guard !loaded.isLocked else { return }
                guard loaded.pageCount > 0 else { throw RecorderError.message("This PDF has no pages.") }
                document = loaded
                let title = url.deletingPathExtension().lastPathComponent
                root = recoveryRoot.appendingPathComponent("\(title)-\(UUID().uuidString.prefix(8)).pdfrecorder")
                newManifest = try ProjectStore.create(at: root, source: url, title: title, pageCount: loaded.pageCount)
            }
            pdf = document; manifest = newManifest; projectURL = root; password = newPassword
            thumbnailCache.removeAllObjects(); artworkCache.removeAllObjects()
            showRecovery = false; status = ""
            loadPage(0)
        } catch { errorMessage = error.localizedDescription }
    }
    func saveAs() {
        guard mode == .idle, let root = projectURL, let manifest else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdfRecorder]; panel.nameFieldStringValue = manifest.title + ".pdfrecorder"
        panel.message = "Save a portable project containing your PDF and every take."
        guard panel.runModal() == .OK, let destination = panel.url, destination != root else { return }
        do {
            guard !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw RecorderError.message("Choose a location outside the current project package.")
            }
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".pdfrecorder-save-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: root, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
            else { try FileManager.default.moveItem(at: staged, to: destination) }
            let wasRecovery = isRecoveryProject
            projectURL = destination
            if wasRecovery { try? FileManager.default.removeItem(at: root) }
            status = "Project saved"
        } catch { errorMessage = "Could not save the project: \(error.localizedDescription)" }
    }
    func navigate(to index: Int) {
        guard canNavigate, let manifest, manifest.pages.indices.contains(index) else { return }
        stopPlayback(); loadPage(index)
    }
    private func loadPage(_ index: Int) {
        pageIndex = index; selectedTakeID = page?.selectedTakeID
        scene = Scene(); time = 0; undoActions = []; timeline = nil
        do {
            let key = NSNumber(value: index)
            if let cached = artworkCache.object(forKey: key) { artwork = cached.value }
            else if let p = pdf?.page(at: index) {
                let value = try PageArtwork(page: p)
                artwork = value; artworkCache.setObject(ArtworkBox(value), forKey: key, cost: value.image.bytesPerRow * value.image.height)
            }
        } catch { artwork = nil; errorMessage = error.localizedDescription }
    }
    func apply(_ action: SceneAction) {
        guard canDraw else { return }
        scene.apply(action)
        if mode == .recording { events.append(TimedEvent(time: microphone.snapshot.time, action: action)) }
    }
    func finishedStroke(_ id: UUID) { undoActions.append(.removeStroke(id)) }
    func erase(_ stroke: Stroke) { apply(.removeStroke(stroke.id)); undoActions.append(.restoreStroke(stroke)) }
    func undo() { guard canDraw, let action = undoActions.popLast() else { return }; apply(action) }
    func zoom(_ factor: Double) {
        guard canDraw else { return }
        var viewport = scene.viewport; viewport.zoom = max(1, min(8, viewport.zoom * factor))
        if viewport.zoom == 1 { viewport.offset = Point(0, 0) }
        apply(.viewport(viewport))
    }
    func fit() { apply(.viewport(Viewport())) }
    func record() {
        guard mode == .idle, artwork != nil, let root = projectURL else { return }
        // Do not overwrite a pending recovery journal before the user can recover it.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("active-take.json").path) {
            let alert = NSAlert(); alert.messageText = "An unfinished take is waiting"
            alert.informativeText = "Recover it before starting a new take, or keep its files aside in this project for later inspection. Your completed takes are safe."
            alert.addButton(withTitle: "Recover & Start New Take")
            alert.addButton(withTitle: "Keep Aside & Start New Take")
            alert.addButton(withTitle: "Cancel")
            do {
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard let manifest else { return }
                    self.manifest = try ProjectStore.recover(at: root, manifest: manifest)
                    selectedTakeID = page?.selectedTakeID
                case .alertSecondButtonReturn: try ProjectStore.setAsideActiveTake(at: root)
                default: return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        mode = .starting
        let take = Take(initialViewport: scene.viewport)
        Task {
            do {
                let url = try ProjectStore.prepare(take, at: root)
                try await microphone.start(deviceID: inputID, url: url)
                activeTake = take; scene = Scene(viewport: take.initialViewport); events = []; undoActions = []
                time = 0; lastJournal = 0; journalEventIndex = 0; mode = .recording; status = ""
                try journal()
            } catch {
                _ = await microphone.stop(); mode = .idle; activeTake = nil
                errorMessage = error.localizedDescription
            }
        }
    }
    func togglePause() {
        guard mode == .recording || mode == .paused else { return }
        if mode == .recording {
            apply(.pointer(nil)); microphone.setPaused(true); mode = .paused
            time = microphone.snapshot.time; level = 0
        } else { microphone.setPaused(false); mode = .recording }
        do { try journal() } catch { errorMessage = error.localizedDescription; Task { await stopRecording() } }
    }
    func stopRecording() async {
        guard mode == .recording || mode == .paused, var take = activeTake, let root = projectURL, let manifest else { return }
        mode = .stopping
        take.duration = await microphone.stop()
        do {
            guard take.duration > 0.05 else {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("active-take.json"))
                throw RecorderError.message("No microphone audio was captured. Check your input and try again.")
            }
            self.manifest = try ProjectStore.commit(take, events: events, page: pageIndex, manifest: manifest, at: root)
            selectedTakeID = take.id; time = take.duration; status = "Take saved automatically"
        } catch { errorMessage = "Could not finish this take: \(error.localizedDescription)" }
        activeTake = nil; mode = .idle; level = 0
    }
    private func journal() throws {
        guard var take = activeTake, let root = projectURL else { return }
        take.duration = microphone.snapshot.time
        journalEventIndex = try ProjectStore.journal(ActiveTake(page: pageIndex, take: take, events: events), from: journalEventIndex, at: root)
    }
    func chooseTake(_ take: Take) {
        guard mode == .idle, var manifest, let root = projectURL else { return }
        do {
            manifest.pages[pageIndex].selectedTakeID = take.id
            try ProjectStore.save(manifest, at: root); self.manifest = manifest; selectedTakeID = take.id
            time = 0; timeline = nil; scene = Scene(viewport: take.initialViewport)
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteTake(_ take: Take) {
        guard mode == .idle, var manifest, let root = projectURL else { return }
        let alert = NSAlert(); alert.messageText = "Delete this take?"; alert.informativeText = "The other takes and your original PDF will be kept. This cannot be undone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Take")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            manifest.pages[pageIndex].delete(take.id)
            try ProjectStore.save(manifest, at: root); self.manifest = manifest
            selectedTakeID = page?.selectedTakeID; time = 0; timeline = nil; scene = Scene()
            // Delete only the files referenced by this take, never an arbitrary parent directory.
            try? FileManager.default.removeItem(at: ProjectStore.location(take.audioPath, in: root))
            try? FileManager.default.removeItem(at: ProjectStore.location(take.eventsPath, in: root))
        } catch { errorMessage = error.localizedDescription }
    }
    func play(all: Bool = false) {
        guard mode == .idle else { if mode == .playing { stopPlayback() }; return }
        let items = all ? (manifest?.selectedTakes ?? []) : selectedTake.map { [(pageIndex, $0)] } ?? []
        guard let first = items.first else { return }
        playbackQueue = Array(items.dropFirst())
        startPlayback(page: first.0, take: first.1, from: all ? 0 : (time >= first.1.duration ? 0 : time))
    }
    private func startPlayback(page index: Int, take: Take, from start: Double) {
        guard let root = projectURL else { return }
        do {
            if pageIndex != index { loadPage(index) }
            selectedTakeID = take.id
            timeline = Timeline(events: try ProjectStore.events(for: take, at: root), initialViewport: take.initialViewport)
            player = try AVAudioPlayer(contentsOf: ProjectStore.location(take.audioPath, in: root))
            player?.currentTime = start; player?.prepareToPlay()
            guard player?.play() == true else { throw RecorderError.message("This recording could not be played.") }
            mode = .playing; time = start
        } catch { stopPlayback(); errorMessage = error.localizedDescription }
    }
    func stopPlayback() {
        player?.stop(); player = nil; playbackQueue = []
        if mode == .playing { mode = .idle }
    }
    func seek(to value: Double) {
        guard mode == .idle || mode == .playing, let take = selectedTake, let root = projectURL else { return }
        do {
            if timeline == nil { timeline = Timeline(events: try ProjectStore.events(for: take, at: root), initialViewport: take.initialViewport) }
            time = max(0, min(value, take.duration)); player?.currentTime = time
            scene = timeline!.seek(to: time)
        } catch { errorMessage = error.localizedDescription }
    }
    private func tick() {
        if mode == .recording || mode == .paused {
            let snapshot = microphone.snapshot; time = snapshot.time; level = snapshot.level
            if mode == .recording && time - lastJournal >= 2 {
                lastJournal = time
                do { try journal() } catch {
                    errorMessage = "Autosave failed: \(error.localizedDescription)"
                    Task { await stopRecording() }
                }
            }
        } else if mode == .playing, let player {
            time = player.currentTime; scene = timeline?.seek(to: time) ?? scene
            if !player.isPlaying {
                time = selectedTake?.duration ?? time; scene = timeline?.seek(to: time) ?? scene
                if !playbackQueue.isEmpty {
                    let next = playbackQueue.removeFirst(); startPlayback(page: next.page, take: next.take, from: 0)
                } else { stopPlayback() }
            }
        }
    }
    func export() {
        guard mode == .idle, let manifest, let root = projectURL, !manifest.selectedTakes.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = manifest.title + ".mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let items = try manifest.selectedTakes.map { item in
                ExportItem(page: item.page, take: item.take, events: try ProjectStore.events(for: item.take, at: root), audioURL: try ProjectStore.location(item.take.audioPath, in: root))
            }
            let pdfURL = try ProjectStore.location(manifest.sourcePDF, in: root)
            let password = self.password
            let progressObserver = self
            mode = .exporting; exportProgress = 0
            exportTask = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) {
                    try await VideoExporter.export(pdfURL: pdfURL, password: password, items: items, to: destination) { value in
                        Task { @MainActor in progressObserver.exportProgress = value }
                    }
                }
                do {
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    self?.status = "Video exported"
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch is CancellationError { self?.status = "Export cancelled" }
                catch { self?.errorMessage = error.localizedDescription }
                self?.mode = .idle; self?.exportTask = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func cancelExport() { exportTask?.cancel() }
    func revealProject() { if let projectURL { NSWorkspace.shared.activateFileViewerSelecting([projectURL]) } }
}
