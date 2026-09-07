// Native SwiftUI adaptations of Rare UI's folder-component and step-player.
// Original components Copyright (c) 2026 Swami Malode, MIT.
// See THIRD_PARTY_NOTICES.md for sources and the full license.
import SwiftUI
import PDFRecorderCore

struct RareFolder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    private let blue = Color(red: 0.22, green: 0.22, blue: 0.25)
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25).fill(blue.gradient).frame(width: 321, height: 270)
                .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.12)))
            ForEach(0..<3) { index in
                folderCard
                    .rotationEffect(.degrees(rotation(index)))
                    .offset(x: [40.0, 3.0, -40.0][index], y: hovered ? [-30.0, -35.0, -44.0][index] : [-10.0, -20.0, -22.0][index])
            }
            FolderFlap().fill(Color(red: 0.16, green: 0.16, blue: 0.18).opacity(0.95).gradient)
                .overlay(FolderFlap().stroke(.white.opacity(0.12), lineWidth: 1))
                .frame(width: 321, height: 241)
                .rotation3DEffect(.degrees(hovered ? -45 : -15), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.6)
                .offset(y: 16)
        }
        .frame(width: 321, height: 300)
        .scaleEffect(0.42)
        .frame(width: 152, height: 135)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 120, damping: 14), value: hovered)
        .accessibilityHidden(true)
    }
    private func rotation(_ index: Int) -> Double { hovered ? [14, -1, -9][index] : [10, 2, -5][index] }
    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Image(systemName: "waveform").foregroundStyle(Color(white: 0.35)); Spacer(); Text("PDF").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.gray) }
            Capsule().fill(Color.gray.opacity(0.22)).frame(height: 11)
            ForEach(0..<5) { index in
                Capsule().fill(Color.gray.opacity(0.15)).frame(width: index == 4 ? 72 : 128, height: 6)
            }
            Spacer(minLength: 0)
        }.padding(17).frame(width: 164, height: 214)
            .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(white: 0.86)))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 3)
    }
}

private struct FolderFlap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 25))
        p.addCurve(to: CGPoint(x: 25, y: 0), control1: CGPoint(x: 0, y: 11.1929), control2: CGPoint(x: 11.1929, y: 0))
        p.addLine(to: CGPoint(x: 136.084, y: 0))
        p.addCurve(to: CGPoint(x: 154.42, y: 8.00608), control1: CGPoint(x: 143.044, y: 0), control2: CGPoint(x: 149.689, y: 2.90139))
        p.addLine(to: CGPoint(x: 178.08, y: 33.5343))
        p.addCurve(to: CGPoint(x: 196.416, y: 41.5404), control1: CGPoint(x: 182.811, y: 38.639), control2: CGPoint(x: 189.456, y: 41.5404))
        p.addLine(to: CGPoint(x: 296, y: 41.5404))
        p.addCurve(to: CGPoint(x: 321, y: 66.5404), control1: CGPoint(x: 309.807, y: 41.5404), control2: CGPoint(x: 321, y: 52.7333))
        p.addLine(to: CGPoint(x: 321, y: 216))
        p.addQuadCurve(to: CGPoint(x: 296, y: 241), control: CGPoint(x: 321, y: 241))
        p.addLine(to: CGPoint(x: 25, y: 241))
        p.addQuadCurve(to: CGPoint(x: 0, y: 216), control: CGPoint(x: 0, y: 241))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 321, y: rect.height / 241))
    }
}

/// A bounded, seekable view of the recorded pages. The active dot expands into a progress track.
@MainActor struct RareStepPlayer: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var items: [(page: Int, take: Take)] { model.manifest?.exportTakes ?? [] }
    private var visible: [Int] {
        let active = items.firstIndex { $0.page == model.pageIndex } ?? 0
        let start = max(0, min(active - 2, items.count - 5))
        return Array(start..<min(items.count, start + 5))
    }
    var body: some View {
        HStack(spacing: 6) {
            Button { model.play(all: model.mode != .playing) } label: {
                Image(systemName: model.mode == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
            }.buttonStyle(.plain).help(model.mode == .playing ? "Pause presentation" : "Preview all recorded pages")
                .accessibilityLabel(model.mode == .playing ? "Pause presentation" : "Preview all recorded pages")
            if items.isEmpty {
                Text("Record a page to preview").font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.self) { index in
                    let item = items[index]
                    let active = item.page == model.pageIndex
                    let progress = active && model.selectedTakeID == item.take.id ? min(1, max(0, (model.time - item.take.playbackStart) / max(0.001, item.take.playbackDuration))) : 0
                    Button { model.navigate(to: item.page); model.seek(to: 0) } label: {
                        Capsule().fill(Color.primary.opacity(0.13))
                            .overlay(alignment: .leading) {
                                if active { Capsule().fill(Color.accentColor).frame(width: max(6, 46 * progress)) }
                            }
                            .frame(width: active ? 46 : 6, height: 6)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Page \(item.page + 1) · \(duration(item.take.playbackDuration))")
                        .accessibilityLabel("Preview page \(item.page + 1)")
                }
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.42, bounce: 0.14), value: model.pageIndex)
        .disabled(model.isRecording || model.mode == .exporting || model.mode == .rehearsing || items.isEmpty)
    }
}
