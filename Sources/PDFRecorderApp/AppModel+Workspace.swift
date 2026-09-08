import SwiftUI
import PDFKit
import PDFRecorderCore

extension AppModel {
    var supportRoot: URL { supportRootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PDF Recorder", isDirectory: true) }
    func loadPreferences() {
        let value = (try? WorkspaceStore.loadPreferences(at: supportRoot)) ?? RecorderPreferences()
        inputID = value.microphoneID; countdownSeconds = [0, 3, 5].contains(value.countdown) ? value.countdown : 3
        playbackRate = min(2, max(0.5, value.playbackRate)); notesFontSize = min(36, max(13, value.notesFontSize))
        focusMode = value.hidePages; hideInspector = value.hideInspector; showNotes = value.showNotes; largeControls = value.largeControls
        advancedUI = value.advancedUI ?? false
        recentProjects = (try? WorkspaceStore.loadRecent(at: supportRoot)) ?? []; preferencesReady = true
    }
    func savePreferences() {
        guard preferencesReady else { return }
        var value = RecorderPreferences()
        value.microphoneID = inputID; value.countdown = countdownSeconds; value.playbackRate = playbackRate
        value.notesFontSize = notesFontSize; value.hidePages = focusMode; value.hideInspector = hideInspector
        value.advancedUI = advancedUI
        value.showNotes = showNotes; value.largeControls = largeControls
        do { try WorkspaceStore.savePreferences(value, at: supportRoot) }
        catch { status = "Preferences could not be saved: \(error.localizedDescription)" }
    }
    func rememberWorkspace() {
        guard let manifest, let projectURL else { return }
        rememberDocumentPosition()
        let positions = Dictionary(uniqueKeysWithValues: documentWorkspaces.map { ($0.key.uuidString, $0.value) })
        var item = RecentProject(manifest: manifest, url: projectURL, workspace: .init(page: pageIndex, viewport: scene.viewport, documents: positions))
        if let old = recentProjects.first(where: { $0.id == item.id }) { item.pinned = old.pinned; item.previewName = old.previewName }
        // Do not create a decrypted thumbnail cache for an encrypted PDF.
        if pdf?.isEncrypted == false, let image = thumbnail(pageIndex), let data = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data), let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) {
            let preview = "previews/\(manifest.id.uuidString).jpg"
            do {
                try FileManager.default.createDirectory(at: supportRoot.appendingPathComponent("previews"), withIntermediateDirectories: true)
                try jpeg.write(to: supportRoot.appendingPathComponent(preview), options: .atomic); item.previewName = preview
            } catch { /* A missing thumbnail must not prevent saving the workspace. */ }
        }
        recentProjects.removeAll { $0.id == item.id }; recentProjects.append(item); recentProjects = WorkspaceStore.sorted(recentProjects)
        do { try WorkspaceStore.saveRecent(recentProjects, at: supportRoot) }
        catch { status = "Recent projects could not be saved: \(error.localizedDescription)" }
    }
    func togglePin(_ project: RecentProject) {
        guard let index = recentProjects.firstIndex(where: { $0.id == project.id }) else { return }
        recentProjects[index].pinned.toggle(); recentProjects = WorkspaceStore.sorted(recentProjects)
        do { try WorkspaceStore.saveRecent(recentProjects, at: supportRoot) } catch { errorMessage = error.localizedDescription }
    }
    func forgetRecent(_ project: RecentProject) {
        recentProjects.removeAll { $0.id == project.id }
        do { try WorkspaceStore.saveRecent(recentProjects, at: supportRoot) } catch { errorMessage = error.localizedDescription }
    }
    func showLibrary() {
        guard mode == .idle, flushMetadata() else { return }
        rememberWorkspace(); stopPlayback(); reviewTask?.cancel(); ocrGeneration = UUID(); ocrTask?.cancel(); ocrTask = nil; ocrProgress = nil
        manifest = nil; pdf = nil; artwork = nil; projectURL = nil
        loadedPDFDocuments = [:]; documentPasswords = [:]; documentWorkspaces = [:]; ocrPages = [:]
    }
    func updateActivity() {
        let active = mode == .recording || mode == .paused || mode == .starting || mode == .stopping || mode == .exporting || mode == .checkingMicrophone
        if active, activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "PDF narration or export is in progress") }
        else if !active, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    func announceMode() {
        let label: String
        switch mode {
        case .recording: label = "Recording started"
        case .paused: label = "Recording paused"
        case .checkingMicrophone: label = "Microphone check active. No audio is saved."
        case .countdown: label = "Recording countdown started"
        case .exporting: label = "Export started"
        case .idle: label = "Ready"
        default: return
        }
        guard let window = NSApp?.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func refreshStorage() {
        guard let root = projectURL, let manifest else { return }
        showStorage = true; storageLoading = true
        Task {
            do {
                let result = try await Task.detached(priority: .utility) { try ProjectRecovery.inspect(manifest: manifest, at: root) }.value
                guard projectURL == root else { return }; storageInventory = result
            } catch { errorMessage = error.localizedDescription }
            storageLoading = false
        }
    }
    func clearPlaybackCache() {
        guard mode == .idle else { return }
        stopPlayback()
        Task {
            do { try await playbackAudioCache.removeAll(); status = "Playback cache cleared · source takes preserved"; refreshStorage() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func makeSnapshot() {
        guard mode == .idle, flushMetadata(), let manifest, let root = projectURL else { return }
        do { try ProjectRecovery.snapshot(manifest, reason: "Saved checkpoint", at: root); status = "Project snapshot saved"; refreshStorage() }
        catch { errorMessage = error.localizedDescription }
    }
    func restoreSnapshot(_ snapshot: ProjectSnapshot) {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        do {
            stopPlayback(); self.manifest = try ProjectRecovery.restoreSnapshot(snapshot, current: manifest, at: root)
            hasUnsavedMetadata = false; loadPage(pageIndex); status = "Snapshot restored; newer takes remain in Trash"; refreshStorage()
        } catch { errorMessage = error.localizedDescription }
    }
    func removeSnapshot(_ snapshot: ProjectSnapshot) {
        guard mode == .idle, let root = projectURL else { return }
        do { try ProjectRecovery.removeSnapshot(snapshot.id, at: root); refreshStorage() } catch { errorMessage = error.localizedDescription }
    }
    func restoreDeletedTake(_ id: UUID) {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        do {
            self.manifest = try ProjectRecovery.restoreTake(id, manifest: manifest, at: root)
            lastDeletedTake = nil; selectedTakeID = page?.selectedTakeID; loadReview(); status = "Take restored"
            if showStorage { refreshStorage() }
        } catch { errorMessage = error.localizedDescription }
    }
    func purgeDeletedTake(_ item: TrashedTake) {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        let alert = NSAlert(); alert.messageText = "Permanently delete this take?"
        alert.informativeText = "This removes its audio and gestures from disk. It cannot be undone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Permanently")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try ProjectRecovery.purgeTake(item.id, manifest: manifest, at: root); refreshStorage() } catch { errorMessage = error.localizedDescription }
    }
    func recoverActiveTake() {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        do { self.manifest = try ProjectStore.recover(at: root, manifest: manifest); loadPage(pageIndex); refreshStorage() } catch { errorMessage = error.localizedDescription }
    }
    func retryUnavailableTakes() {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        do { self.manifest = try ProjectRecovery.retryUnavailable(manifest, at: root); loadPage(pageIndex); refreshStorage() } catch { errorMessage = error.localizedDescription }
    }
    func recoverSetAside(_ name: String) {
        guard mode == .idle, let manifest, let root = projectURL else { return }
        do { self.manifest = try ProjectRecovery.recoverSetAside(name, manifest: manifest, at: root); loadPage(pageIndex); refreshStorage() } catch { errorMessage = error.localizedDescription }
    }
    func startOCR() {
        guard mode == .idle, ocrTask == nil, let root = projectURL, let source = currentDocument,
              let range = manifest?.pageRange(for: source.id) else { return }
        let url = root.appendingPathComponent(source.path), password = documentPasswords[source.id]
        let cache = ocrCacheDirectory(for: source, at: root)
        let generation = UUID(); ocrGeneration = generation; ocrProgress = 0
        ocrTask = Task {
            defer {
                if ocrGeneration == generation {
                    ocrGeneration = UUID(); ocrProgress = nil; ocrTask = nil
                }
            }
            do {
                let pages = try await OCRReading.recognize(pdfURL: url, password: password, cacheDirectory: cache) { value in
                    Task { @MainActor in if self.ocrGeneration == generation { self.ocrProgress = value } }
                }
                guard projectURL == root, ocrGeneration == generation else { return }
                for (index, content) in pages where (0..<source.pageCount).contains(index) { ocrPages[range.lowerBound + index] = content }
                indexedPageText = []; scheduleSearch(); status = "Text recognized in \(source.title)"
            } catch is CancellationError { if ocrGeneration == generation { status = "Text recognition cancelled" } }
            catch { if ocrGeneration == generation { errorMessage = error.localizedDescription } }
        }
    }
    var pageLabel: String { pdfPage(at: pageIndex).map { PDFReading.label(for: $0, index: currentDocumentPageNumber - 1) } ?? "\(currentDocumentPageNumber)" }
    func navigate(toLabel label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = currentDocumentPages.first(where: { pdfPage(at: $0)?.label == label }) { navigate(to: index) }
        else if let number = Int(label), (1...max(1, currentDocumentPages.count)).contains(number) { navigate(to: currentDocumentPages.lowerBound + number - 1) }
    }
    var outlineItems: [PDFOutlineItem] {
        guard let pdf else { return [] }
        let offset = currentDocumentPages.lowerBound
        return PDFReading.outline(in: pdf).map { item in
            PDFOutlineItem(id: "\(currentDocumentID?.uuidString ?? "")-\(item.id)", title: item.title, page: item.page + offset, depth: item.depth)
        }
    }
}
