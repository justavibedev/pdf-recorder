import SwiftUI
import PDFRecorderCore

@MainActor struct WaveformTimelineView: View {
    @ObservedObject var model: AppModel
    private var canSeek: Bool { model.mode == .idle || model.mode == .playing }
    var body: some View {
        if let take = model.selectedTake {
            VStack(spacing: 5) {
                HStack {
                    Text("\(duration(max(0, model.time - take.playbackStart))) / \(duration(take.playbackDuration))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if model.reviewLoading {
                        ProgressView().controlSize(.mini)
                        Text("Reading waveform…").font(.caption2).foregroundStyle(.secondary)
                    } else if let waveform = model.waveform {
                        Text(waveform.clipped ? "Clipping" : waveform.isSilent ? "Silence" : waveform.isQuiet ? "Quiet recording" : "Speech waveform")
                            .font(.caption2).foregroundStyle(waveform.clipped ? Color.red : Color.secondary)
                            .help(waveform.feedback)
                    }
                }
                GeometryReader { geometry in
                    Canvas { context, size in
                        draw(context: &context, size: size, take: take)
                    }
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard canSeek, geometry.size.width > 0 else { return }
                        model.seek(to: Double(value.location.x / geometry.size.width) * take.duration)
                    })
                    .accessibilityHidden(true)
                }.frame(height: model.largeControls ? 66 : 44)
                Slider(value: Binding(get: { max(take.playbackStart, min(take.playbackEnd, model.time)) }, set: { model.seek(to: $0) }),
                       in: take.playbackStart...max(take.playbackStart + 0.001, take.playbackEnd))
                    .controlSize(.small).disabled(!canSeek)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(duration(max(0, model.time - take.playbackStart))) of \(duration(take.playbackDuration))")
                    .accessibilityHint("Adjust to scrub the kept portion of this take.")
                if take.playbackStart > 0 || take.playbackEnd < take.duration {
                    HStack { Text("Dimmed audio is trimmed out"); Spacer(); Text("Source \(duration(model.time))") }
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func draw(context: inout GraphicsContext, size: CGSize, take: Take) {
        guard take.duration > 0 else { return }
        let mid = size.height / 2
        func x(_ time: Double) -> CGFloat { CGFloat(max(0, min(1, time / take.duration))) * size.width }
        var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: mid)); baseline.addLine(to: CGPoint(x: size.width, y: mid))
        context.stroke(baseline, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        if let analysis = model.waveform, !analysis.bins.isEmpty {
            let step = size.width / CGFloat(analysis.bins.count)
            for (index, bin) in analysis.bins.enumerated() {
                let height = max(1, CGFloat(sqrt(Double(min(1, bin.peak)))) * (size.height - 9))
                let rect = CGRect(x: CGFloat(index) * step, y: mid - height / 2, width: max(0.7, step * 0.8), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(bin.clipped ? .red.opacity(0.8) : .accentColor.opacity(0.5)))
                let rmsHeight = max(0.5, CGFloat(sqrt(Double(min(1, bin.rms)))) * (size.height - 9))
                context.fill(Path(CGRect(x: rect.minX, y: mid - rmsHeight / 2, width: rect.width, height: rmsHeight)), with: .color(.accentColor.opacity(0.5)))
            }
        }
        let start = x(take.playbackStart), end = x(take.playbackEnd)
        if start > 0 { context.fill(Path(CGRect(x: 0, y: 0, width: start, height: size.height)), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.78))) }
        if end < size.width { context.fill(Path(CGRect(x: end, y: 0, width: size.width - end, height: size.height)), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.78))) }
        if model.loopEnabled, let loop = take.loopRange {
            context.fill(Path(CGRect(x: x(loop.start), y: 0, width: max(0, x(loop.end) - x(loop.start)), height: size.height)), with: .color(.orange.opacity(0.12)))
            for point in [loop.start, loop.end] {
                var boundary = Path(); boundary.move(to: CGPoint(x: x(point), y: 0)); boundary.addLine(to: CGPoint(x: x(point), y: size.height))
                context.stroke(boundary, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        for marker in take.reviewMarkers ?? [] {
            let at = x(marker.time)
            var triangle = Path(); triangle.move(to: CGPoint(x: at - 3.5, y: size.height)); triangle.addLine(to: CGPoint(x: at + 3.5, y: size.height)); triangle.addLine(to: CGPoint(x: at, y: size.height - 6)); triangle.closeSubpath()
            context.fill(triangle, with: .color(.orange))
        }
        let at = x(model.time)
        var playhead = Path(); playhead.move(to: CGPoint(x: at, y: 0)); playhead.addLine(to: CGPoint(x: at, y: size.height))
        context.stroke(playhead, with: .color(.primary), lineWidth: 1.5)
    }
}
