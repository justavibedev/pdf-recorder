import SwiftUI
import PDFKit
import AVFoundation
import UniformTypeIdentifiers
import PDFRecorderCore

extension UTType { static let pdfRecorder = UTType(exportedAs: "org.pdfrecorder.project", conformingTo: .package) }

@MainActor final class AppModel: ObservableObject {
    enum Mode { case idle, countdown, starting, recording, paused, stopping, playing, rehearsing, exporting, loadingPlayback, checkingMicrophone }
    enum ExportKind: String, CaseIterable { case video = "Video (MP4)", audio = "Audio only (M4A)" }
    @Published var manifest: ProjectManifest? { didSet { refreshPageMatches() } }
    @Published var pdf: PDFDocument?
    @Published var projectURL: URL?
    @Published var pageIndex = 0
    @Published var artwork: PageArtwork?
    @Published var scene = Scene()
    @Published var mode = Mode.idle { didSet { updateTimer(); updateActivity(); announceMode() } }
    @Published var tool = InkTool.pointer
    @Published var inkColor = "blue"
    @Published var time = 0.0
    @Published var level = 0.0
    @Published var errorMessage: String?
    @Published var status = ""
    @Published var inputID = "" { didSet { savePreferences() } }
    @Published var inputs: [AVCaptureDevice] = []
    @Published var exportProgress = 0.0
    @Published var exportSummary = false
    @Published var recoveryProjects: [URL] = []
    @Published var showRecovery = false
    @Published var selectedTakeID: UUID?
    @Published var searchQuery = "" { didSet { scheduleSearch() } }
    @Published var pageFilter = PageFilter.all { didSet { refreshPageMatches() } }
    @Published var visiblePageIndices: [Int] = []
    @Published var isSearching = false
    @Published var showNotes = false { didSet { savePreferences() } }
    @Published var focusMode = false { didSet { savePreferences() } }
    @Published var hideInspector = false { didSet { savePreferences() } }
    @Published var largeControls = false { didSet { savePreferences() } }
    @Published var countdownSeconds = 3 { didSet { savePreferences() } }
    @Published var countdownRemaining = 0
    @Published var playbackRate: Float = 1 { didSet { player?.rate = playbackRate; savePreferences() } }
    @Published var exportKind = ExportKind.video
    @Published var notesFontSize = 17.0 { didSet { savePreferences() } }
    @Published var hasUnsavedMetadata = false
    @Published var annotationWidth = 0.003
    @Published var annotationOpacity = 1.0
    @Published var annotationText = "Text"
    @Published var ocrPages: [Int: PageReadingContent] = [:]
    @Published var ocrProgress: Double?
    @Published var recentProjects: [RecentProject] = []
    @Published var storageInventory: StorageInventory?
    @Published var showStorage = false
    @Published var storageLoading = false
    @Published var showCommands = false
    @Published var focusSearchToken = 0
    @Published var waveform: WaveformAnalysis?
    @Published var reviewLoading = false
    @Published var comparisonTakeID: UUID?
    @Published var loopEnabled = false
    @Published var microphoneFeedback = ""
    @Published var exportPreset = ExportPreset.standard
    @Published var exportScope = ExportScope.included
    @Published var exportRange = ""
    @Published var exportSeparately = false
    @Published var exportStartedAt = Date()
    @Published var rehearsalHistory: [RehearsalReport] = []
    @Published var showRehearsalHistory = false
    var rehearsalSession: RehearsalSession?
    lazy var presenterDisplay = PresenterDisplayController(model: self)
    var preferencesReady = false
    var supportRootOverride: URL?
    var activity: NSObjectProtocol?
    var reviewTask: Task<Void, Never>?
    var reviewGeneration = UUID()
    var reviewRenderScene = true
    var playbackTask: Task<Void, Never>?
    var playbackGeneration = UUID()
    var ocrTask: Task<Void, Never>?
    var ocrGeneration = UUID()
    var playbackPaused = false
    var playbackIsPresentation = false
    var playbackClip: URL?
    var lastDeletedTake: UUID?
    var redoActions: [[SceneAction]] = []
    var groupedUndoActions: [[SceneAction]] = []
    var metadataSaveTask: Task<Void, Never>?
    var countdownTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var indexedPageText: [String] = []
    var rehearsalStart = 0.0
    let microphone = MicrophoneRecorder()
    var activeTake: Take?
    var events: [TimedEvent] = []
    var undoActions: [SceneAction] = []
    var player: (any PlaybackTransport)?
    var timeline: Timeline?
    var playbackQueue: [(page: Int, take: Take)] = []
    var timer: Timer?
    var lastJournal = 0.0
    var journalEventIndex = 0
    var exportTask: Task<Void, Never>?
    var password: String?
    var thumbnailCache = NSCache<NSNumber, NSImage>()
    var artworkCache = NSCache<NSNumber, ArtworkBox>()
    class ArtworkBox { let value: PageArtwork; init(_ value: PageArtwork) { self.value = value } }
    var page: PageRecord? { guard let manifest, manifest.pages.indices.contains(pageIndex) else { return nil }; return manifest.pages[pageIndex] }
    var selectedTake: Take? { page?.takes.first { $0.id == selectedTakeID } }
    var canNavigate: Bool { mode == .idle || mode == .playing || mode == .rehearsing }
    var canDraw: Bool { artwork != nil && (mode == .idle || mode == .recording || mode == .rehearsing) }
    var isRecording: Bool { mode == .recording || mode == .paused || mode == .starting || mode == .stopping || mode == .countdown }
    var totalDuration: Double { manifest?.exportTakes.reduce(0) { $0 + $1.take.playbackDuration } ?? 0 }
    var targetDuration: Double { manifest?.pages.filter { $0.includedInExport != false }.reduce(0) { $0 + ($1.targetSeconds ?? 0) } ?? 0 }
    var recoveryRoot: URL {
        supportRoot.appendingPathComponent("Recovery", isDirectory: true)
    }
    var isRecoveryProject: Bool { projectURL?.path.hasPrefix(recoveryRoot.path + "/") ?? false }

    init(storageRoot: URL? = nil, connectDevices: Bool = true) {
        supportRootOverride = storageRoot
        loadPreferences()
        artworkCache.totalCostLimit = 100 * 1024 * 1024
        artworkCache.countLimit = 3
        thumbnailCache.countLimit = 100
        if connectDevices { refreshInputs() }
        microphone.onFailure = { [weak self] message in
            if let self, self.mode == .checkingMicrophone { Task { await self.stopMicrophoneCheck(); self.errorMessage = message }; return }
            guard let self, self.mode == .recording || self.mode == .paused else { return }
            Task { await self.stopRecording(); self.errorMessage = message }
        }
        discoverRecovery()
    }
    func updateTimer() {
        timer?.invalidate(); timer = nil
        guard mode == .recording || mode == .playing || mode == .rehearsing || mode == .checkingMicrophone else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.tick() }
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
    func unlock(_ document: PDFDocument) -> String? {
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
        guard mode == .idle, flushMetadata() else { return }
        rememberWorkspace(); stopPlayback(); ocrGeneration = UUID(); ocrTask?.cancel(); ocrTask = nil; ocrProgress = nil
        do {
            let root: URL
            var newManifest: ProjectManifest
            let document: PDFDocument
            var newPassword: String?
            if url.pathExtension.lowercased() == "pdfrecorder" {
                root = url
                do { newManifest = try ProjectStore.load(at: root) }
                catch {
                    let readable = try ProjectStore.load(at: root, allowingMissingMedia: true)
                    let missing = readable.pages.flatMap(\.takes).filter { !ProjectRecovery.mediaExists($0, at: root) }
                    guard !missing.isEmpty else { throw error }
                    let alert = NSAlert(); alert.messageText = "Some take files are unavailable"
                    alert.informativeText = "Open the healthy pages and keep metadata for \(missing.count) unavailable takes in the Recovery Center. Their files can be restored later."
                    alert.addButton(withTitle: "Open Healthy Pages"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    newManifest = try ProjectRecovery.isolateMissingMedia(readable, at: root)
                }
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
            searchTask?.cancel(); indexedPageText = []; searchQuery = ""; pageFilter = .all
            pdf = document; manifest = newManifest; projectURL = root; password = newPassword
            thumbnailCache.removeAllObjects(); artworkCache.removeAllObjects()
            showRecovery = false; status = ""
            ocrPages = (try? OCRReading.loadCache(pdfURL: root.appendingPathComponent(newManifest.sourcePDF), cacheDirectory: root.appendingPathComponent("reading"))) ?? [:]
            let restored = recentProjects.first { $0.id == newManifest.id }?.workspace ?? ProjectWorkspace()
            loadPage(max(0, min(newManifest.pages.count - 1, restored.page)))
            scene.viewport = restored.viewport
            rememberWorkspace(); loadRehearsalHistory()
        } catch { errorMessage = error.localizedDescription }
    }
    func saveAs() {
        guard mode == .idle, let root = projectURL, let manifest else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdfRecorder]; panel.nameFieldStringValue = manifest.title + ".pdfrecorder"
        panel.message = "Save a portable project containing your PDF and every take."
        guard panel.runModal() == .OK, let destination = panel.url, destination != root else { return }
        do {
            try ProjectStore.saveCopy(from: root, to: destination, manifest: manifest)
            let wasRecovery = isRecoveryProject
            projectURL = destination
            hasUnsavedMetadata = false; metadataSaveTask?.cancel(); loadReview(renderScene: false); rememberWorkspace()
            if wasRecovery { try? FileManager.default.removeItem(at: root) }
            status = "Project saved"
        } catch { errorMessage = "Could not save the project: \(error.localizedDescription)" }
    }
    func navigate(to index: Int) {
        guard canNavigate, let manifest, manifest.pages.indices.contains(index) else { return }
        if mode == .rehearsing { rehearsalVisitPage(index) }
        stopPlayback(); loadPage(index)
    }
    func loadPage(_ index: Int) {
        pageIndex = index; selectedTakeID = page?.selectedTakeID
        scene = Scene(); time = selectedTake?.playbackStart ?? 0; undoActions = []; timeline = nil
        redoActions = []; groupedUndoActions = []; loopEnabled = false; comparisonTakeID = nil
        if mode == .rehearsing { rehearsalStart = ProcessInfo.processInfo.systemUptime }
        do {
            let key = NSNumber(value: index)
            if let cached = artworkCache.object(forKey: key) { artwork = cached.value }
            else if let p = pdf?.page(at: index) {
                let value = try PageArtwork(page: p)
                artwork = value; artworkCache.setObject(ArtworkBox(value), forKey: key, cost: value.image.bytesPerRow * value.image.height)
            }
        } catch { artwork = nil; errorMessage = error.localizedDescription }
        loadReview(renderScene: false); rememberWorkspace()
    }
    func apply(_ action: SceneAction) {
        guard canDraw else { return }
        scene.apply(action)
        if mode == .recording { events.append(TimedEvent(time: microphone.snapshot.time, action: action)) }
    }
    func finishedStroke(_ id: UUID) { groupedUndoActions.append([.removeStroke(id)]); redoActions = [] }
    func erase(_ stroke: Stroke) { apply(.removeStroke(stroke.id)); groupedUndoActions.append([.restoreStroke(stroke)]); redoActions = [] }
    func undo() {
        guard canDraw, let actions = groupedUndoActions.popLast() else { return }
        var inverseActions: [SceneAction] = []
        for action in actions { if let redo = inverse(action) { inverseActions.insert(redo, at: 0) }; apply(action) }
        redoActions.append(inverseActions)
    }
    func zoom(_ factor: Double) {
        guard canDraw else { return }
        var viewport = scene.viewport; viewport.zoom = max(1, min(8, viewport.zoom * factor))
        if viewport.zoom == 1 { viewport.offset = Point(0, 0) }
        apply(.viewport(viewport))
    }
    func fit() { apply(.viewport(Viewport())) }
    func record() {
        guard mode == .idle, artwork != nil, flushMetadata(), let root = projectURL else { return }
        stopPlayback(); reviewTask?.cancel()
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
        countdownRemaining = countdownSeconds
        mode = countdownSeconds > 0 ? .countdown : .starting
        let take = Take(initialViewport: scene.viewport)
        countdownTask = Task {
            do {
                try await RecordingCountdown.run(seconds: countdownSeconds) { remaining in self.countdownRemaining = remaining }
                try Task.checkCancellation()
                countdownRemaining = 0; mode = .starting
                let url = try ProjectStore.prepare(take, at: root)
                try await microphone.start(deviceID: inputID, url: url)
                activeTake = take; scene = Scene(viewport: take.initialViewport); events = []; undoActions = []
                groupedUndoActions = []; redoActions = []; timeline = nil; waveform = nil
                time = 0; lastJournal = 0; journalEventIndex = 0; mode = .recording; status = ""
                try journal()
            } catch is CancellationError {
                countdownRemaining = 0; mode = .idle; loadReview(renderScene: false)
            } catch {
                _ = await microphone.stop(); mode = .idle; activeTake = nil; loadReview(renderScene: false)
                errorMessage = error.localizedDescription
            }
            countdownTask = nil
        }
    }
    func cancelCountdown() { guard mode == .countdown else { return }; countdownTask?.cancel() }
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
        activeTake = nil; mode = .idle; level = 0; loadReview(); rememberWorkspace()
    }
    func journal() throws {
        guard var take = activeTake, let root = projectURL else { return }
        take.duration = microphone.snapshot.time
        journalEventIndex = try ProjectStore.journal(ActiveTake(page: pageIndex, take: take, events: events), from: journalEventIndex, at: root)
    }
    func chooseTake(_ take: Take) {
        guard mode == .idle || mode == .playing else { return }
        stopPlayback(); selectedTakeID = take.id; time = take.playbackStart
        timeline = nil; scene = Scene(viewport: take.initialViewport); groupedUndoActions = []; redoActions = []; loopEnabled = false; loadReview()
    }
    func useTake(_ take: Take) {
        guard mode == .idle, var manifest, let root = projectURL else { return }
        do {
            manifest.pages[pageIndex].selectedTakeID = take.id
            try ProjectStore.save(manifest, at: root); self.manifest = manifest; hasUnsavedMetadata = false
            status = "Export take selected"; rememberWorkspace()
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteTake(_ take: Take) {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        do {
            stopPlayback()
            self.manifest = try ProjectRecovery.trashTake(take.id, page: pageIndex, manifest: manifest, at: root)
            lastDeletedTake = take.id; selectedTakeID = page?.selectedTakeID
            time = selectedTake?.playbackStart ?? 0; timeline = nil; scene = Scene(); loadReview()
            status = "Take moved to Trash · Undo Delete is available"; rememberWorkspace()
        } catch { errorMessage = error.localizedDescription }
    }
    func play(all: Bool = false) {
        if mode == .playing {
            if let player, let take = selectedTake { time = player.currentTime + take.playbackStart; scene = timeline?.seek(to: time) ?? scene }
            player?.pause(); mode = .idle; playbackPaused = true; return
        }
        guard mode == .idle else { return }
        if playbackPaused, playbackIsPresentation == all, let player, let take = selectedTake {
            if time >= take.playbackEnd { time = take.playbackStart; player.currentTime = 0; scene = timeline?.seek(to: time) ?? scene }
            guard player.play() else { stopPlayback(); errorMessage = "Playback could not resume. Try playing the take again."; return }
            playbackPaused = false; mode = .playing; return
        }
        if playbackPaused { stopPlayback() }
        playbackIsPresentation = all
        if all { loopEnabled = false }
        let items = all ? (manifest?.exportTakes ?? []) : selectedTake.map { [(pageIndex, $0)] } ?? []
        guard let first = items.first else { return }
        playbackQueue = Array(items.dropFirst())
        var start = all ? first.1.playbackStart : (time >= first.1.playbackEnd ? first.1.playbackStart : max(time, first.1.playbackStart))
        if loopEnabled, let loop = first.1.loopRange, start < loop.start || start >= loop.end { start = loop.start }
        startPlayback(page: first.0, take: first.1, from: start)
    }
    func startPlayback(page index: Int, take: Take, from start: Double) {
        guard let root = projectURL else { return }
        if pageIndex != index { loadPage(index) }
        selectedTakeID = take.id; reviewTask?.cancel(); playbackPaused = false; mode = .loadingPlayback
        let matchLoudness = manifest?.matchLoudness == true
        let generation = UUID(); playbackGeneration = generation
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-recorder-preview-\(UUID().uuidString).caf")
        playbackTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () throws -> (Timeline, WaveformAnalysis) in
                try await AudioProcessing.renderPlayback(take: take, source: ProjectStore.location(take.audioPath, in: root), to: clip, matchLoudness: matchLoudness)
                let timeline = Timeline(events: try ProjectStore.events(for: take, at: root), initialViewport: take.initialViewport)
                let waveform = try AudioAnalysis.analyze(url: ProjectStore.location(take.audioPath, in: root))
                return (timeline, waveform)
            }
            do {
                let loaded = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.playbackGeneration == generation else { try? FileManager.default.removeItem(at: clip); return }
                if let old = self.playbackClip { try? FileManager.default.removeItem(at: old) }
                self.playbackClip = clip; self.timeline = loaded.0; self.waveform = loaded.1; self.reviewLoading = false
                self.player = try AVAudioPlayer(contentsOf: clip); self.player?.enableRate = true; self.player?.rate = self.playbackRate
                self.player?.currentTime = max(0, start - take.playbackStart); self.player?.prepareToPlay()
                guard self.player?.play() == true else { throw RecorderError.message("This recording could not be played.") }
                self.time = start; self.scene = self.timeline!.seek(to: start); self.mode = .playing
            } catch {
                try? FileManager.default.removeItem(at: clip)
                if self?.playbackGeneration == generation {
                    if !(error is CancellationError) { self?.errorMessage = error.localizedDescription }
                    if self?.mode == .loadingPlayback { self?.mode = .idle }
                }
            }
        }
    }
    func stopPlayback() {
        playbackGeneration = UUID()
        playbackTask?.cancel(); playbackTask = nil; player?.stop(); player = nil; playbackQueue = []; playbackPaused = false
        if let clip = playbackClip { try? FileManager.default.removeItem(at: clip); playbackClip = nil }
        if mode == .playing || mode == .loadingPlayback { mode = .idle }
    }
    func seek(to value: Double) {
        guard mode == .idle || mode == .playing, let take = selectedTake else { return }
        time = max(take.playbackStart, min(value, take.playbackEnd)); player?.currentTime = time - take.playbackStart
        if timeline != nil { scene = timeline!.seek(to: time) }
        else { reviewRenderScene = true; if !reviewLoading { loadReview() } }
    }
    func tick() {
        if mode == .checkingMicrophone {
            let snapshot = microphone.snapshot; level = snapshot.level; microphoneFeedback = snapshot.feedback
        } else if mode == .rehearsing {
            time = max(0, ProcessInfo.processInfo.systemUptime - rehearsalStart)
        } else if mode == .recording || mode == .paused {
            let snapshot = microphone.snapshot; time = snapshot.time; level = snapshot.level
            if mode == .recording && time - lastJournal >= 2 {
                lastJournal = time
                do { try journal() } catch {
                    errorMessage = "Autosave failed: \(error.localizedDescription)"
                    Task { await stopRecording() }
                }
            }
        } else if mode == .playing, let player {
            time = player.currentTime + (selectedTake?.playbackStart ?? 0)
            if loopEnabled, let range = selectedTake?.loopRange, time < range.start || time >= range.end || !player.isPlaying {
                time = range.start; player.currentTime = time - (selectedTake?.playbackStart ?? 0); if !player.isPlaying { player.play() }
            }
            scene = timeline?.seek(to: time) ?? scene
            if !player.isPlaying {
                time = selectedTake?.playbackEnd ?? time; scene = timeline?.seek(to: time) ?? scene
                if !playbackQueue.isEmpty {
                    let next = playbackQueue.removeFirst(); startPlayback(page: next.page, take: next.take, from: next.take.playbackStart)
                } else { stopPlayback() }
            }
        }
    }
    func cancelExport() { exportTask?.cancel() }
    func revealProject() { if let projectURL { NSWorkspace.shared.activateFileViewerSelecting([projectURL]) } }

    func pageTitle(_ index: Int) -> String {
        guard let manifest, manifest.pages.indices.contains(index) else { return "Page \(index + 1)" }
        return PresentationTools.title(for: manifest.pages[index], index: index)
    }
    func updatePage(_ change: (inout PageRecord) -> Void) {
        guard mode == .idle, var updated = manifest else { return }
        change(&updated.pages[pageIndex]); manifest = updated; hasUnsavedMetadata = true
        metadataSaveTask?.cancel()
        metadataSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000); _ = self?.flushMetadata() }
            catch {}
        }
    }
    @discardableResult func flushMetadata() -> Bool {
        metadataSaveTask?.cancel(); metadataSaveTask = nil
        guard hasUnsavedMetadata, let manifest, let root = projectURL else { return true }
        do { try ProjectStore.save(manifest, at: root); hasUnsavedMetadata = false; return true }
        catch { errorMessage = "Presenter notes or page settings could not be saved: \(error.localizedDescription)"; return false }
    }
    func toggleBookmark() { updatePage { $0.bookmarked = !($0.bookmarked ?? false) } }
    func nextUnrecorded() {
        guard canNavigate else { return }
        guard let manifest, let next = PresentationTools.nextUnrecorded(in: manifest, after: pageIndex) else { status = "Every page has a recording"; return }
        searchQuery = ""; pageFilter = .unfinished
        navigate(to: next)
    }
    func refreshPageMatches() {
        guard let manifest else { visiblePageIndices = []; return }
        visiblePageIndices = PresentationTools.matchingPages(in: manifest, query: searchQuery, filter: pageFilter, pageText: indexedPageText)
    }
    func scheduleSearch() {
        searchTask?.cancel(); refreshPageMatches(); isSearching = false
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let manifest, indexedPageText.count != manifest.pages.count, let root = projectURL else { return }
        let id = manifest.id, password = self.password, ocr = ocrPages
        let url = root.appendingPathComponent(manifest.sourcePDF)
        isSearching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                let worker = Task.detached(priority: .userInitiated) { () throws -> [String] in
                    guard let document = PDFDocument(url: url) else { return [] }
                    if document.isLocked { _ = document.unlock(withPassword: password ?? "") }
                    return try (0..<document.pageCount).map { index in
                        try Task.checkCancellation(); return ocr[index]?.text ?? document.page(at: index)?.string ?? ""
                    }
                }
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.manifest?.id == id else { return }
                self.indexedPageText = text; self.isSearching = false; self.refreshPageMatches()
            } catch { /* A superseded query must not overwrite the new query's state. */ }
        }
    }
    func togglePractice() {
        if mode == .rehearsing {
            finishRehearsal()
            mode = .idle; time = 0; timeline = nil
            scene = Scene(viewport: scene.viewport); undoActions = []; groupedUndoActions = []; redoActions = []
            status = "Practice complete · no recording saved"; return
        }
        guard mode == .idle, artwork != nil, flushMetadata() else { return }
        stopPlayback(); beginRehearsal()
        rehearsalStart = ProcessInfo.processInfo.systemUptime; time = 0; timeline = nil
        scene = Scene(viewport: scene.viewport); undoActions = []; groupedUndoActions = []; redoActions = []; showNotes = true; hideInspector = false; mode = .rehearsing
    }
    func skipPlayback(_ seconds: Double) {
        guard let take = selectedTake else { return }
        seek(to: max(take.playbackStart, min(take.playbackEnd, time + seconds)))
    }
    func exportNotes() {
        guard mode == .idle, flushMetadata(), let manifest else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.nameFieldStringValue = manifest.title + " — Notes.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PresentationTools.notesMarkdown(manifest).write(to: url, atomically: true, encoding: .utf8); status = "Presenter notes exported" }
        catch { errorMessage = error.localizedDescription }
    }
}
