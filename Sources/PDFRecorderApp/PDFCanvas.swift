import AppKit
import SwiftUI
import PDFKit
import PDFRecorderCore

@MainActor struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeNSView(context: Context) -> CanvasView { let view = CanvasView(); view.model = model; return view }
    func updateNSView(_ view: CanvasView, context: Context) { view.model = model; view.refreshReading(); view.needsDisplay = true }
}

@MainActor
final class CanvasView: NSView, NSMenuItemValidation {
    weak var model: AppModel?
    private var tracking: NSTrackingArea?
    private var strokeID: UUID?
    private var lastDrag: CGPoint?
    private var lastPointerTime = 0.0
    private weak var readingPage: PDFPage?
    private var reading = PageReadingContent(text: "", characterBounds: [])
    private var cachedOCRText: String?
    private var cachedQuery = ""
    private var searchBoxes: [PageTextRect] = []
    private var selectionBoxes: [PageTextRect] = []
    private var selectedText = ""
    private var selectionStart: Point?
    private var announcedState = ""
    override var acceptsFirstResponder: Bool { true }
    func refreshReading() {
        guard let model, let page = model.pdfPage(at: model.pageIndex) else { return }
        let ocr = model.ocrPages[model.pageIndex]
        let changed = readingPage !== page || cachedOCRText != ocr?.text
        if changed {
            readingPage = page; cachedOCRText = ocr?.text
            reading = ocr ?? PDFReading.content(of: page)
            selectedText = ""; selectionBoxes = []; selectionStart = nil
            setAccessibilityElement(true); setAccessibilityRole(.textArea)
            setAccessibilityLabel("PDF page \(model.pageLabel)")
            setAccessibilityValue(reading.text.isEmpty ? "Scanned page. Use Recognize Text to make this page readable." : reading.text)
            setAccessibilityHelp("Select Text to drag and copy. Arrow or Page Up and Page Down keys navigate. P pen, H highlighter, V pointer, E eraser, T text, A arrow, R rectangle, O ellipse, L line, S select text. Plus and minus zoom.")
        }
        if changed || model.searchQuery != cachedQuery {
            cachedQuery = model.searchQuery
            searchBoxes = PDFReading.matches(query: cachedQuery, in: reading)
        }
        let state = String(describing: model.mode)
        if state != announcedState {
            announcedState = state
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(state.capitalized), page \(model.pageLabel)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model, let artwork = model.artwork, let context = NSGraphicsContext.current?.cgContext else { return }
        SceneRenderer.draw(artwork: artwork, scene: model.scene, in: context, bounds: bounds)
        guard let geometry else { return }
        context.saveGState(); context.clip(to: bounds)
        for (boxes, color) in [(searchBoxes, NSColor.systemYellow.withAlphaComponent(0.32)), (selectionBoxes, NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4))] {
            context.setFillColor(color.cgColor)
            for box in boxes {
                let origin = geometry.toCanvas(Point(box.x, box.y))
                context.fill(CGRect(x: origin.x, y: origin.y, width: box.width * geometry.pageRect.width, height: box.height * geometry.pageRect.height))
            }
        }
        context.restoreGState()
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
        case .pen, .highlighter, .line, .arrow, .rectangle, .ellipse, .text:
            let stroke = Stroke(tool: model.tool, color: model.tool == .highlighter && model.inkColor == "blue" ? "yellow" : model.inkColor,
                                width: model.annotationWidth * (model.tool == .highlighter ? 8 : 1), points: [point],
                                opacity: model.annotationOpacity * (model.tool == .highlighter ? 0.36 : 1),
                                shape: AnnotationShape(rawValue: model.tool.rawValue), text: model.tool == .text ? model.annotationText : nil)
            strokeID = stroke.id; model.apply(.beginStroke(stroke))
        case .eraser: erase(at: location, geometry: geometry)
        case .selectText:
            selectionStart = point; selectedText = ""; selectionBoxes = []
            if event.clickCount == 2, let page = readingPage, cachedOCRText == nil,
               let selection = page.selectionForWord(at: PDFReading.pagePoint(point, on: page)) {
                updateSelection(selection, page: page)
            }
            needsDisplay = true
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
        } else if model.tool == .selectText, let start = selectionStart {
            let end = geometry.toPage(location)
            if let page = readingPage, cachedOCRText == nil,
               let selection = page.selection(from: PDFReading.pagePoint(start, on: page), to: PDFReading.pagePoint(end, on: page)) {
                updateSelection(selection, page: page)
            } else {
                let rectangle = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                let selection = PDFReading.selectedText(in: reading, rectangle: rectangle)
                selectedText = selection.text; selectionBoxes = selection.boxes
            }
            needsDisplay = true
        } else if let strokeID, model.tool != .text {
            if geometry.pageRect.contains(location) { model.apply(.extendStroke(strokeID, geometry.toPage(location))) }
        } else if model.tool == .eraser { erase(at: location, geometry: geometry) }
        lastDrag = location
        model.apply(.pointer(geometry.toPage(location)))
    }
    override func mouseUp(with event: NSEvent) {
        if let strokeID { model?.finishedStroke(strokeID) }
        strokeID = nil; lastDrag = nil; selectionStart = nil
    }
    private func updateSelection(_ selection: PDFSelection, page: PDFPage) {
        selectedText = selection.string ?? ""
        selectionBoxes = selection.selectionsByLine().map { PDFReading.normalized($0.bounds(for: page), on: page) }
    }
    @objc func copy(_ sender: Any?) {
        guard !selectedText.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string)
    }
    override func selectAll(_ sender: Any?) {
        selectedText = reading.text; selectionBoxes = reading.characterBounds.filter { !$0.rect.isEmpty }; needsDisplay = true
    }
    @objc func undo(_ sender: Any?) { model?.undo() }
    @objc func redo(_ sender: Any?) { model?.redo() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return model?.canDraw == true && !(model?.groupedUndoActions.isEmpty ?? true)
        case #selector(redo(_:)): return model?.canDraw == true && !(model?.redoActions.isEmpty ?? true)
        case #selector(copy(_:)): return !selectedText.isEmpty
        case #selector(selectAll(_:)): return !reading.text.isEmpty
        default: return true
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Selected Text", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self; copy.isEnabled = !selectedText.isEmpty; menu.addItem(copy)
        let all = NSMenuItem(title: "Select All Page Text", action: #selector(selectAll(_:)), keyEquivalent: "")
        all.target = self; menu.addItem(all)
        return menu
    }
    private func erase(at location: CGPoint, geometry: PageGeometry) {
        guard let model else { return }
        for stroke in model.scene.strokes.reversed() {
            if AnnotationGeometry.hitTest(stroke, at: location, geometry: geometry) { model.erase(stroke); return }
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
        // Canvas shortcuts only run while this canvas has focus. Text fields keep ordinary typing and editing.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() {
            let tools: [String: InkTool] = ["v": .pointer, "p": .pen, "h": .highlighter, "e": .eraser, "a": .arrow, "r": .rectangle, "o": .ellipse, "l": .line, "t": .text, "s": .selectText, "m": .pan]
            if let tool = tools[key], model.canDraw { model.tool = tool; return }
            if key == "+" || key == "=" { model.zoom(1.2); return }
            if key == "-" { model.zoom(1 / 1.2); return }
            if key == "0" { model.fit(); return }
        }
        switch event.keyCode {
        case 123, 126, 116: model.navigatePage(-1)
        case 124, 125, 121: model.navigatePage(1)
        case 115: model.navigate(to: model.currentDocumentPages.lowerBound)
        case 119: model.navigate(to: model.currentDocumentPages.upperBound - 1)
        case 49:
            if model.mode == .rehearsing { model.togglePractice() }
            else if model.isRecording { model.togglePause() } else { model.play() }
        case 53: model.cancelCountdown()
        default: super.keyDown(with: event)
        }
    }
}
