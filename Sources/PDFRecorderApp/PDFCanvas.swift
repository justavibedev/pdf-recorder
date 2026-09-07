import AppKit
import SwiftUI
import PDFRecorderCore

@MainActor struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> CanvasView { let view = CanvasView(); view.model = model; return view }
    func updateNSView(_ view: CanvasView, context: Context) { view.model = model; view.needsDisplay = true }
}

final class CanvasView: NSView {
    weak var model: AppModel?
    private var tracking: NSTrackingArea?
    private var strokeID: UUID?
    private var lastDrag: CGPoint?
    private var lastPointerTime = 0.0
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model, let artwork = model.artwork, let context = NSGraphicsContext.current?.cgContext else { return }
        SceneRenderer.draw(artwork: artwork, scene: model.scene, in: context, bounds: bounds)
    }
    private var geometry: PageGeometry? {
        guard let model, let artwork = model.artwork else { return nil }
        return PageGeometry(canvas: bounds, pageSize: artwork.size, viewport: model.scene.viewport)
    }
    override func mouseMoved(with event: NSEvent) {
        guard let model, model.canDraw, let geometry, event.timestamp - lastPointerTime >= 1.0 / 60 else { return }
        lastPointerTime = event.timestamp
        let location = convert(event.locationInWindow, from: nil)
        model.apply(.pointer(bounds.contains(location) ? geometry.toPage(location) : nil))
    }
    override func mouseExited(with event: NSEvent) { model?.apply(.pointer(nil)) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, model.canDraw, let geometry else { return }
        let location = convert(event.locationInWindow, from: nil)
        lastDrag = location
        let point = geometry.toPage(location)
        model.apply(.pointer(point))
        guard geometry.pageRect.contains(location) else { return }
        switch model.tool {
        case .pen, .highlighter:
            let stroke = Stroke(tool: model.tool, color: model.tool == .highlighter && model.inkColor == "blue" ? "yellow" : model.inkColor,
                                width: model.tool == .highlighter ? 0.025 : 0.003, points: [point])
            strokeID = stroke.id; model.apply(.beginStroke(stroke))
        case .eraser: erase(at: location, geometry: geometry)
        default: break
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let model, model.canDraw, let geometry else { return }
        let location = convert(event.locationInWindow, from: nil)
        if model.tool == .pan {
            if let lastDrag {
                var v = model.scene.viewport
                v.offset.x += (location.x - lastDrag.x) / bounds.width
                v.offset.y += (location.y - lastDrag.y) / bounds.height
                model.apply(.viewport(v))
            }
        } else if let strokeID {
            if geometry.pageRect.contains(location) { model.apply(.extendStroke(strokeID, geometry.toPage(location))) }
        } else if model.tool == .eraser { erase(at: location, geometry: geometry) }
        lastDrag = location
        model.apply(.pointer(geometry.toPage(location)))
    }
    override func mouseUp(with event: NSEvent) {
        if let strokeID { model?.finishedStroke(strokeID) }
        strokeID = nil; lastDrag = nil
    }
    private func erase(at location: CGPoint, geometry: PageGeometry) {
        guard let model else { return }
        for stroke in model.scene.strokes.reversed() {
            let points = stroke.points.map(geometry.toCanvas)
            let tolerance = max(10, stroke.width * geometry.pageRect.width / 2)
            let hit = points.contains { hypot($0.x - location.x, $0.y - location.y) <= tolerance }
                || zip(points, points.dropFirst()).contains { a, b in
                    let dx = b.x - a.x, dy = b.y - a.y
                    let denominator = dx * dx + dy * dy
                    let t = denominator == 0 ? 0 : max(0, min(1, ((location.x - a.x) * dx + (location.y - a.y) * dy) / denominator))
                    return hypot(location.x - (a.x + t * dx), location.y - (a.y + t * dy)) <= tolerance
                }
            if hit { model.erase(stroke); return }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard let model, model.canDraw else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            model.zoom(exp(event.scrollingDeltaY * 0.01))
        } else {
            var viewport = model.scene.viewport
            viewport.offset.x += event.scrollingDeltaX / bounds.width
            viewport.offset.y -= event.scrollingDeltaY / bounds.height
            model.apply(.viewport(viewport))
        }
    }
    override func magnify(with event: NSEvent) { model?.zoom(1 + event.magnification) }
    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        switch event.keyCode {
        case 123, 126: model.navigate(to: model.pageIndex - 1)
        case 124, 125: model.navigate(to: model.pageIndex + 1)
        case 49:
            if model.isRecording { model.togglePause() } else { model.play() }
        default: super.keyDown(with: event)
        }
    }
}
