import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PDFRecorderCore

final class CanvasFeatureTests: XCTestCase {
    func testVectorDrawingMatchesPDFKitWithRotationCropAndOriginalAnnotations() throws {
        let document = fixturePDF()
        let page = document.page(at: 0)!
        page.setBounds(CGRect(x: 20, y: 30, width: 550, height: 700), for: .cropBox)
        let annotation = PDFAnnotation(bounds: CGRect(x: 220, y: 260, width: 80, height: 100), forType: .square, withProperties: nil)
        annotation.interiorColor = .red; annotation.color = .red; page.addAnnotation(annotation)
        let canvas = CGRect(x: 0, y: 0, width: 960, height: 540)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let artwork = try PageArtwork(page: page, maximumDimension: 1400)
            let actual = SceneRenderer.image(artwork: artwork, scene: Scene(), size: canvas.size)!
            let context = CGContext(data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.075, green: 0.085, blue: 0.11, alpha: 1)); context.fill(canvas)
            let rect = PageGeometry(canvas: canvas, pageSize: artwork.size, viewport: Viewport()).pageRect
            context.draw(artwork.image, in: rect)
            let expected = context.makeImage()!
            let difference = zip(pixels(expected), pixels(actual)).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels(expected).count)
            XCTAssertLessThan(difference, 4, "Vector renderer and PDFKit disagree at rotation \(rotation)")
        }
    }
    func testDeepZoomUsesPDFVectorsRegardlessOfPreviewResolution() throws {
        let document = textPDF()
        let smallPreview = try PageArtwork(page: document.page(at: 0)!, maximumDimension: 24)
        let fullPreview = try PageArtwork(page: document.page(at: 0)!, maximumDimension: 1600)
        let scene = Scene(viewport: Viewport(zoom: 8, offset: Point(0, -0.55)))
        let size = CGSize(width: 960, height: 540)
        let low = SceneRenderer.image(artwork: smallPreview, scene: scene, size: size)!
        let high = SceneRenderer.image(artwork: fullPreview, scene: scene, size: size)!
        XCTAssertLessThanOrEqual(smallPreview.image.width, 24)
        XCTAssertEqual(pixels(low), pixels(high), "Deep-zoom detail must not depend on preview bitmap size")
        let data = pixels(high)
        let dark = stride(from: 0, to: data.count, by: 4).filter { data[$0] < 30 && data[$0 + 1] < 30 && data[$0 + 2] < 30 }.count
        XCTAssertGreaterThan(dark, 100, "The zoomed paragraph must still contain solid, sharp text")
    }
    func testNativeSearchHighlightsExactTextAndTransformsRotatedPages() throws {
        let document = textPDF(), page = document.page(at: 0)!
        page.setBounds(CGRect(x: 50, y: 40, width: 512, height: 710), for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let content = PDFReading.content(of: page)
            XCTAssertTrue(content.text.contains("Student"))
            let matches = PDFReading.matches(query: "student", in: content)
            XCTAssertEqual(matches.count, 7)
            for box in matches {
                XCTAssertGreaterThan(box.width, 0); XCTAssertGreaterThan(box.height, 0)
                XCTAssertGreaterThanOrEqual(box.x, 0); XCTAssertLessThanOrEqual(box.rect.maxX, 1)
                XCTAssertGreaterThanOrEqual(box.y, 0); XCTAssertLessThanOrEqual(box.rect.maxY, 1)
                let center = PDFReading.pagePoint(Point(box.rect.midX, box.rect.midY), on: page)
                XCTAssertNotEqual(page.characterIndex(at: center), NSNotFound)
            }
            XCTAssertTrue(PDFReading.matches(query: "missing text", in: content).isEmpty)
        }
    }
    func testShapesOpacityTextAndEraserUseRecordedGeometry() throws {
        let geometry = PageGeometry(canvas: CGRect(x: 0, y: 0, width: 1000, height: 1000), pageSize: CGSize(width: 100, height: 100), viewport: Viewport())
        let rectangle = Stroke(tool: .rectangle, color: "red", width: 0.003, points: [Point(0.2, 0.2), Point(0.8, 0.8)], opacity: 0.5, shape: .rectangle)
        XCTAssertTrue(AnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 200, y: 500), geometry: geometry))
        XCTAssertFalse(AnnotationGeometry.hitTest(rectangle, at: CGPoint(x: 500, y: 500), geometry: geometry))
        var ellipse = rectangle; ellipse.tool = .ellipse; ellipse.shape = .ellipse
        XCTAssertTrue(AnnotationGeometry.hitTest(ellipse, at: CGPoint(x: 500, y: 800), geometry: geometry))
        XCTAssertFalse(AnnotationGeometry.hitTest(ellipse, at: CGPoint(x: 200, y: 200), geometry: geometry))
        let text = Stroke(tool: .text, color: "blue", width: 0.01, points: [Point(0.3, 0.4)], opacity: 0.8, shape: .text, text: "Presenter")
        XCTAssertTrue(AnnotationGeometry.hitTest(text, at: CGPoint(x: 350, y: 420), geometry: geometry))
        let events = [TimedEvent(time: 0, action: .beginStroke(rectangle)), .init(time: 1, action: .beginStroke(text)),
                      .init(time: 2, action: .removeStroke(rectangle.id)), .init(time: 3, action: .restoreStroke(rectangle))]
        let decoded = try JSONDecoder().decode([TimedEvent].self, from: JSONEncoder().encode(events))
        var timeline = Timeline(events: decoded, initialViewport: Viewport())
        XCTAssertEqual(timeline.seek(to: 0.5).strokes, [rectangle])
        XCTAssertEqual(timeline.seek(to: 2.5).strokes, [text])
        XCTAssertEqual(timeline.seek(to: 3.5).strokes, [text, rectangle])
        XCTAssertEqual(timeline.seek(to: 0.5).strokes.first?.opacity, 0.5)
    }
    func testOutlineAndPrintedPageLabels() throws {
        let document = labeledPDF()
        XCTAssertEqual(PDFReading.label(for: document.page(at: 0)!, index: 0), "i")
        XCTAssertEqual(PDFReading.label(for: document.page(at: 1)!, index: 1), "ii")
        XCTAssertEqual(PDFReading.label(for: document.page(at: 2)!, index: 2), "1")
        let root = PDFOutline(), chapter = PDFOutline(), section = PDFOutline()
        chapter.label = "Introduction"; chapter.destination = PDFDestination(page: document.page(at: 0)!, at: .zero)
        section.label = "First example"; section.destination = PDFDestination(page: document.page(at: 2)!, at: .zero)
        chapter.insertChild(section, at: 0); root.insertChild(chapter, at: 0); document.outlineRoot = root
        let outline = PDFReading.outline(in: document)
        XCTAssertEqual(outline.map(\.page), [0, 2]); XCTAssertEqual(outline.map(\.depth), [0, 1])
        XCTAssertEqual(outline.map(\.title), ["Introduction", "First example"])
    }
    func testOCRCacheRoundTripInvalidatesChangedPDFWithoutEditingSource() async throws {
        let workspace = try scratch(); defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("source.pdf"), cache = workspace.appendingPathComponent("reading")
        let original = textPDF().dataRepresentation()!
        try original.write(to: source)
        let results = try await OCRReading.recognize(pdfURL: source, password: nil, cacheDirectory: cache, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try OCRReading.loadCache(pdfURL: source, cacheDirectory: cache), results)
        XCTAssertTrue(results[0]!.text.contains("Student"))
        try fixturePDF().dataRepresentation()!.write(to: source)
        XCTAssertTrue(try OCRReading.loadCache(pdfURL: source, cacheDirectory: cache).isEmpty)
    }
    func testOfflineOCRRecognizesSyntheticScanAndReturnsSearchGeometry() throws {
        let size = CGSize(width: 1200, height: 350)
        let context = CGContext(data: nil, width: 1200, height: 350, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        drawText("Student rehearsal notes", at: CGPoint(x: 80, y: 160), size: 64, context: context)
        let content = try OCRReading.recognize(image: context.makeImage()!)
        XCTAssertTrue(content.text.localizedCaseInsensitiveContains("Student rehearsal notes"))
        XCTAssertEqual(content.characterBounds.count, content.text.utf16.count)
        let matches = PDFReading.matches(query: "rehearsal", in: content)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.allSatisfy { $0.y > 0.3 && $0.rect.maxY < 0.8 })
        let selection = PDFReading.selectedText(in: content, rectangle: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(selection.text, content.text)
    }
}

private func drawText(_ string: String, at point: CGPoint, size: CGFloat, context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
    let value = CFAttributedStringCreate(nil, string as CFString, attributes)!
    context.textMatrix = .identity; context.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(value), context)
}

private func textPDF() -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    drawText("Student rehearsal notes", at: CGPoint(x: 120, y: 450), size: 24, context: context)
    context.endPDFPage(); context.closePDF()
    return PDFDocument(data: data as Data)!
}

private func labeledPDF() -> PDFDocument {
    let objects = ["<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /St 1 >>] >> >>",
                   "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
                   "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
                   "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
                   "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"]
    var data = "%PDF-1.4\n", offsets = [0]
    for (index, object) in objects.enumerated() { offsets.append(data.utf8.count); data += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
    let xref = data.utf8.count
    data += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() { data += String(format: "%010d 00000 n \n", offset) }
    data += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF"
    return PDFDocument(data: Data(data.utf8))!
}
