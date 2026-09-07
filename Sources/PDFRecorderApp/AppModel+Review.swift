import SwiftUI
import PDFRecorderCore

extension AppModel {
    func loadReview(renderScene: Bool = true) {
        reviewTask?.cancel(); waveform = nil; reviewRenderScene = renderScene
        let generation = UUID(); reviewGeneration = generation
        guard let take = selectedTake, let root = projectURL else { reviewLoading = false; return }
        let index = pageIndex; reviewLoading = true
        reviewTask = Task {
            do {
                let reader = Task.detached(priority: .userInitiated) {
                    Timeline(events: try ProjectStore.events(for: take, at: root), initialViewport: take.initialViewport)
                }
                let loaded = try await withTaskCancellationHandler(operation: { try await reader.value }, onCancel: { reader.cancel() })
                try Task.checkCancellation()
                guard reviewGeneration == generation, selectedTakeID == take.id, pageIndex == index, projectURL == root else { return }
                timeline = loaded
                if mode == .idle, reviewRenderScene { time = max(take.playbackStart, min(take.playbackEnd, time)); scene = timeline!.seek(to: time) }
                if let cached = waveformCache.object(forKey: take.id as NSUUID)?.value { waveform = cached; reviewLoading = false; return }
                // Make the timeline seekable before scanning the waveform of a long recording.
                let analyzer = Task.detached(priority: .utility) { try AudioAnalysis.analyze(url: ProjectStore.location(take.audioPath, in: root)) }
                let analysis = try await withTaskCancellationHandler(operation: { try await analyzer.value }, onCancel: { analyzer.cancel() })
                try Task.checkCancellation()
                guard reviewGeneration == generation, selectedTakeID == take.id, pageIndex == index, projectURL == root else { return }
                waveform = analysis; waveformCache.setObject(WaveformBox(analysis), forKey: take.id as NSUUID); reviewLoading = false
            } catch {
                if reviewGeneration == generation, !(error is CancellationError) { errorMessage = error.localizedDescription; reviewLoading = false }
            }
        }
    }
    func updateTake(_ change: (inout Take) -> Void) {
        guard mode == .idle, var updated = manifest, let root = projectURL,
              let index = updated.pages[pageIndex].takes.firstIndex(where: { $0.id == selectedTakeID }) else { return }
        let old = updated.pages[pageIndex].takes[index]
        change(&updated.pages[pageIndex].takes[index])
        var take = updated.pages[pageIndex].takes[index]
        if let loop = take.loopRange, loop.start < take.playbackStart || loop.end > take.playbackEnd { take.loopRange = nil; loopEnabled = false; updated.pages[pageIndex].takes[index] = take }
        guard take.playbackDuration >= 0.05, take.playbackDuration.isFinite else { errorMessage = "Keep at least 0.05 seconds of this take."; return }
        do {
            try ProjectStore.validateTake(take)
            try ProjectStore.save(updated, at: root); manifest = updated; hasUnsavedMetadata = false
            if old.trimStart != take.trimStart || old.trimEnd != take.trimEnd || old.gainDB != take.gainDB {
                stopPlayback(); time = max(take.playbackStart, min(time, take.playbackEnd)); loadReview()
            }
            status = "Take changes saved · original audio kept"; rememberWorkspace()
        } catch { errorMessage = error.localizedDescription }
    }
    func addReviewMarker(_ label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        updateTake { take in
            var markers = take.reviewMarkers ?? []; markers.append(ReviewMarker(time: time, label: label))
            take.reviewMarkers = markers.sorted { $0.time < $1.time }
        }
    }
    func compareTake() {
        guard mode == .idle || mode == .playing, let otherID = comparisonTakeID,
              let other = page?.takes.first(where: { $0.id == otherID }), let current = selectedTake else { return }
        let offset = max(0, time - current.playbackStart), wasPlaying = mode == .playing
        chooseTake(other); comparisonTakeID = current.id; time = min(max(other.playbackStart, other.playbackEnd - 0.05), other.playbackStart + offset)
        if wasPlaying { play() }
    }
    func setMatchLoudness(_ enabled: Bool) {
        guard mode == .idle, var manifest, let root = projectURL else { return }
        manifest.matchLoudness = enabled
        do { try ProjectStore.save(manifest, at: root); self.manifest = manifest; stopPlayback() } catch { errorMessage = error.localizedDescription }
    }
    func clearMarks() {
        guard canDraw, !scene.strokes.isEmpty else { return }
        let strokes = scene.strokes
        for stroke in strokes { apply(.removeStroke(stroke.id)) }
        groupedUndoActions.append(strokes.enumerated().map { .restoreStroke($0.element, index: $0.offset) }); redoActions = []
    }
    func inverse(_ action: SceneAction) -> SceneAction? {
        switch action {
        case .removeStroke(let id):
            guard let index = scene.strokes.firstIndex(where: { $0.id == id }) else { return nil }
            return .restoreStroke(scene.strokes[index], index: index)
        case .restoreStroke(let stroke, _): return .removeStroke(stroke.id)
        default: return nil
        }
    }
    func redo() {
        guard canDraw, let actions = redoActions.popLast() else { return }
        var inverseActions: [SceneAction] = []
        for action in actions { if let undo = inverse(action) { inverseActions.insert(undo, at: 0) }; apply(action) }
        groupedUndoActions.append(inverseActions)
    }
    func startMicrophoneCheck() {
        guard mode == .idle else { return }
        stopPlayback(); mode = .starting; status = "Starting microphone check · no audio will be saved"
        Task {
            do { try await microphone.start(deviceID: inputID, url: nil); mode = .checkingMicrophone; microphoneFeedback = "Speak normally to check your level" }
            catch { _ = await microphone.stop(); mode = .idle; errorMessage = error.localizedDescription }
        }
    }
    func stopMicrophoneCheck() async {
        guard mode == .checkingMicrophone else { return }
        mode = .stopping; _ = await microphone.stop(); mode = .idle; level = 0; status = "Microphone check ended · no audio was saved"
    }
}
