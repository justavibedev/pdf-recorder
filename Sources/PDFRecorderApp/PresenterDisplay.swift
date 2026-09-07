import AppKit
import SwiftUI
import PDFRecorderCore

@MainActor final class PresenterPrompterState: ObservableObject {
    @Published var enabled = false
    @Published var paused = false
    @Published var speed = 24.0
    func toggle() {
        if enabled { paused.toggle() }
        else { enabled = true; paused = false }
    }
}

/// The audience renderer receives artwork, scene, and navigation only; notes and presenter controls stay in the main window.
@MainActor final class PresenterDisplayController: NSObject, ObservableObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var window: NSWindow?
    @Published private(set) var visible = false
    @Published var screenID: String = ""
    let prompter = PresenterPrompterState()
    var screens: [NSScreen] { NSScreen.screens }
    init(model: AppModel) { self.model = model }
    func show() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "PDF Recorder — Audience"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.collectionBehavior = [.fullScreenPrimary]
            window.backgroundColor = .black
            window.contentView = NSHostingView(rootView: AudienceDisplay(model: model))
            self.window = window
            let screen = screens.first { $0 != NSScreen.main } ?? NSScreen.main
            if let screen { move(to: screen) }
        }
        visible = true; window?.orderFront(nil)
    }
    func move(to screen: NSScreen) {
        screenID = Self.identifier(screen)
        guard let window else { return }
        // Keep a small border while windowed. Full screen is always an explicit user action.
        window.setFrame(screen.visibleFrame.insetBy(dx: 24, dy: 24), display: true)
    }
    func move(to identifier: String) {
        if let screen = screens.first(where: { Self.identifier($0) == identifier }) { move(to: screen) }
    }
    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { visible = false }
    static func identifier(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }
}

@MainActor private struct AudienceDisplay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        AudienceCanvas(artwork: model.artwork, scene: model.scene) { step in
            model.navigate(to: model.pageIndex + step)
        }
            .background(.black)
            .accessibilityLabel("Audience PDF canvas")
            .accessibilityValue("Page \(model.pageIndex + 1)")
    }
}

@MainActor private struct AudienceCanvas: NSViewRepresentable {
    let artwork: PageArtwork?
    let scene: PDFRecorderCore.Scene
    let navigate: (Int) -> Void
    func makeNSView(context: Context) -> AudienceCanvasView { AudienceCanvasView() }
    func updateNSView(_ view: AudienceCanvasView, context: Context) {
        view.artwork = artwork; view.scene = scene; view.navigate = navigate; view.needsDisplay = true
    }
}

@MainActor private final class AudienceCanvasView: NSView {
    var artwork: PageArtwork?
    var scene = PDFRecorderCore.Scene()
    var navigate: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123, 126, 116: navigate?(-1)
        case 124, 125, 121: navigate?(1)
        case 53:
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            else { window?.close() }
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(bounds)
        guard let artwork else { return }
        let width = min(bounds.width, bounds.height * 16 / 9)
        let height = width * 9 / 16
        let canvas = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        SceneRenderer.draw(artwork: artwork, scene: scene, in: context, bounds: canvas)
    }
}

@MainActor struct PresenterDisplayControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: PresenterDisplayController
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button(action: model.showAudienceDisplay) { Label(controller.visible ? "Show Audience" : "Audience Display", systemImage: "display.2") }
                Spacer()
                if controller.visible { Button("Close", action: controller.close).buttonStyle(.borderless) }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    if controller.visible {
                        HStack {
                            Picker("Display", selection: Binding(get: { controller.screenID }, set: { controller.move(to: $0) })) {
                                ForEach(controller.screens, id: \.self) { screen in
                                    Text(screen.localizedName).tag(PresenterDisplayController.identifier(screen))
                                }
                            }.labelsHidden().accessibilityLabel("Audience display screen")
                            Button(action: controller.toggleFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                                .help("Toggle audience full screen").accessibilityLabel("Toggle audience full screen")
                        }
                        Text("Only the PDF and marks appear on the audience display.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let manifest = model.manifest, model.pageIndex + 1 < manifest.pages.count {
                        HStack(spacing: 10) {
                            if let image = model.thumbnail(model.pageIndex + 1) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 76, height: 48)
                                    .accessibilityLabel("Preview of next page")
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("UP NEXT · \(model.pageIndex + 2)").font(.caption2).foregroundStyle(.secondary)
                                Text(model.pageTitle(model.pageIndex + 1)).font(.caption).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    } else { Text("Final page").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button { model.navigate(to: model.pageIndex - 1) } label: { Image(systemName: "chevron.left") }.help("Previous page")
                            .accessibilityLabel("Previous page")
                            .disabled(!model.canNavigate || model.pageIndex == 0)
                        Text("\(model.pageIndex + 1) / \(model.manifest?.pages.count ?? 0)").font(.caption.monospacedDigit())
                        Button { model.navigate(to: model.pageIndex + 1) } label: { Image(systemName: "chevron.right") }.help("Next page")
                            .accessibilityLabel("Next page")
                            .disabled(!model.canNavigate || model.pageIndex + 1 >= (model.manifest?.pages.count ?? 0))
                        Spacer()
                        Text(duration(model.time)).font(.caption.monospacedDigit())
                        if model.mode == .recording || model.mode == .paused {
                            Button(model.mode == .paused ? "Resume" : "Pause", action: model.togglePause)
                        } else if model.mode == .idle || model.mode == .rehearsing {
                            Button(model.mode == .rehearsing ? "End Practice" : "Practice", action: model.togglePractice)
                        }
                    }
                }
            } label: { Text("Next page & presentation controls") }
        }.font(.caption)
            .onChange(of: controller.visible) { _, visible in if visible { expanded = true } }
            .onChange(of: model.mode) { _, mode in if mode == .rehearsing { expanded = true } }
    }
}

@MainActor struct RehearsalHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    private var report: RehearsalReport? { model.rehearsalHistory.first { $0.id == selectedID } ?? model.rehearsalHistory.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rehearsal reports").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let report {
                Picker("Session", selection: Binding(get: { selectedID ?? report.id }, set: { selectedID = $0 })) {
                    ForEach(model.rehearsalHistory) { item in Text(item.startedAt.formatted(date: .abbreviated, time: .standard)).tag(item.id) }
                }
                HStack(spacing: 22) {
                    Label("\(duration(report.totalSeconds)) actual", systemImage: "stopwatch")
                    Label("\(duration(report.plannedSeconds)) planned", systemImage: "timer")
                    Text("\(report.visitedPages)/\(report.pages.count) pages visited")
                }.font(.callout)
                Table(report.pages) {
                    TableColumn("Page") { item in Text("\(item.page + 1)") }.width(38)
                    TableColumn("Title", value: \.title)
                    TableColumn("Planned") { item in Text(item.targetSeconds.map(duration) ?? "—") }.width(65)
                    TableColumn("Actual") { item in Text(item.visits > 0 ? duration(item.actualSeconds) : "—") }.width(65)
                    TableColumn("Over target") { item in Text(item.overrun > 0 ? "+\(duration(item.overrun))" : "—").foregroundStyle(item.overrun > 0 ? Color.orange : .secondary) }.width(85)
                    TableColumn("Visits") { item in Text("\(item.visits)") }.width(40)
                }.frame(minHeight: 190)
                HStack {
                    Text("Repeated visits accumulate. Unvisited pages stay visible.\nTiming only · no microphone recording.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export Report…") { model.exportRehearsal(report) }
                }
            } else {
                ContentUnavailableView("No rehearsals yet", systemImage: "stopwatch", description: Text("Practice a presentation to keep page timings and compare them with your targets."))
            }
        }.padding(24).frame(minWidth: 680, idealWidth: 750, minHeight: 410)
    }
}
