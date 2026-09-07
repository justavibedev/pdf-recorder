import AppKit
import PDFKit
import CoreText
import Darwin

/// All page coordinates use the displayed (rotation-corrected) page: origin bottom-left, range 0...1.
public struct PageGeometry {
    public let canvas: CGRect
    public let pageSize: CGSize
    public let viewport: Viewport
    public var pageRect: CGRect {
        let scale = min(canvas.width / pageSize.width, canvas.height / pageSize.height) * CGFloat(viewport.zoom)
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(x: canvas.midX - size.width / 2 + CGFloat(viewport.offset.x) * canvas.width,
                      y: canvas.midY - size.height / 2 + CGFloat(viewport.offset.y) * canvas.height,
                      width: size.width, height: size.height)
    }
    public init(canvas: CGRect, pageSize: CGSize, viewport: Viewport) {
        self.canvas = canvas; self.pageSize = pageSize; self.viewport = viewport
    }
    public func toCanvas(_ point: Point) -> CGPoint {
        CGPoint(x: pageRect.minX + CGFloat(point.x) * pageRect.width, y: pageRect.minY + CGFloat(point.y) * pageRect.height)
    }
    public func toPage(_ point: CGPoint) -> Point {
        Point(Double((point.x - pageRect.minX) / pageRect.width), Double((point.y - pageRect.minY) / pageRect.height))
    }
}

public struct PageArtwork {
    /// A bounded preview for thumbnails and OCR. Canvas and export draw the PDF itself at their output resolution.
    public let image: CGImage
    public let size: CGSize
    private let page: PDFPage
    private let renderCache = ArtworkRenderCache()
    // PDFPage does not retain its document. Keep the owner alive for lazy image and annotation resources.
    private let document: PDFDocument?
    public init(page: PDFPage, maximumDimension: CGFloat = 1280) throws {
        self.page = page; document = page.document
        let bounds = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw RecorderError.message("This PDF page has invalid dimensions.")
        }
        let scale = maximumDimension / max(size.width, size.height)
        let thumbnail = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
        var rect = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw RecorderError.message("This PDF page could not be rendered.")
        }
        self.image = image
    }
    public func draw(in context: CGContext, rect: CGRect) {
        let clip = context.boundingBoxOfClipPath.intersection(rect)
        guard !clip.isNull, !clip.isEmpty else { return }
        let transform = context.ctm
        let scaleX = (transform.a * transform.a + transform.b * transform.b).squareRoot()
        let scaleY = (transform.c * transform.c + transform.d * transform.d).squareRoot()
        let width = Int(ceil(clip.width * scaleX)), height = Int(ceil(clip.height * scaleY))
        // Cache only the visible viewport at actual output resolution. Pointer movement does not redraw the PDF.
        // Zooming/panning invalidates this image. Huge output contexts use vectors directly instead of downscaling.
        if width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 {
            let key = ArtworkRenderCache.Key(clip: clip, pageRect: rect, width: width, height: height)
            if let image = renderCache.image(for: key) { context.draw(image, in: clip); return }
            if let rendered = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                rendered.scaleBy(x: CGFloat(width) / clip.width, y: CGFloat(height) / clip.height)
                rendered.translateBy(x: -clip.minX, y: -clip.minY)
                rendered.setFillColor(CGColor(gray: 1, alpha: 1)); rendered.fill(clip)
                drawVectors(in: rendered, rect: rect)
                if let image = rendered.makeImage() { renderCache.set(image, for: key); context.draw(image, in: clip); return }
            }
        }
        drawVectors(in: context, rect: rect)
    }
    private func drawVectors(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        // PDFKit draws vectors at the destination's resolution and decodes scanned images only as needed.
        // draw(with:to:) includes the crop offset, page rotation and existing PDF annotations.
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        withExtendedLifetime(document) {}
    }
}

private final class ArtworkRenderCache {
    struct Key: Equatable { let clip: CGRect, pageRect: CGRect; let width: Int, height: Int }
    private let lock = NSLock()
    private var entries: [(Key, CGImage)] = []
    func image(for key: Key) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.0 == key }) else { return nil }
        let entry = entries.remove(at: index); entries.append(entry); return entry.1
    }
    func set(_ value: CGImage, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.0 == key }; entries.append((key, value))
        // Keep the editor and audience viewport independently warm without growing
        // with each zoom step. Bound each page's combined cached backgrounds to64MB.
        while entries.count > 2 || (entries.count > 1 && entries.reduce(0, { $0 + $1.1.bytesPerRow * $1.1.height }) > 64 * 1024 * 1024) { entries.removeFirst() }
    }
}

public enum SceneRenderer {
    public static func color(_ name: String) -> CGColor {
        switch name {
        case "yellow": return CGColor(red: 1, green: 0.79, blue: 0.12, alpha: 1)
        case "red": return CGColor(red: 0.96, green: 0.24, blue: 0.29, alpha: 1)
        case "green": return CGColor(red: 0.15, green: 0.75, blue: 0.48, alpha: 1)
        case "purple": return CGColor(red: 0.65, green: 0.39, blue: 0.96, alpha: 1)
        default: return CGColor(red: 0.19, green: 0.49, blue: 1, alpha: 1)
        }
    }
    public static func draw(artwork: PageArtwork, scene: Scene, in context: CGContext, bounds: CGRect) {
        context.saveGState()
        context.clip(to: bounds)
        context.setFillColor(CGColor(red: 0.075, green: 0.085, blue: 0.11, alpha: 1))
        context.fill(bounds)
        let geometry = PageGeometry(canvas: bounds, pageSize: artwork.size, viewport: scene.viewport)
        let rect = geometry.pageRect
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        context.interpolationQuality = .high
        artwork.draw(in: context, rect: rect)
        context.saveGState()
        context.clip(to: rect)
        for stroke in scene.strokes {
            guard let first = stroke.points.first else { continue }
            context.saveGState()
            context.setStrokeColor(color(stroke.color))
            context.setFillColor(color(stroke.color))
            let width = CGFloat(stroke.width) * rect.width
            context.setLineWidth(width)
            context.setLineCap(.round); context.setLineJoin(.round)
            context.setAlpha(CGFloat(max(0.02, min(1, stroke.opacity ?? (stroke.tool == .highlighter ? 0.36 : 1)))))
            if stroke.tool == .highlighter { context.setBlendMode(.multiply) }
            if let shape = AnnotationGeometry.shape(of: stroke) {
                drawShape(shape, stroke: stroke, geometry: geometry, context: context)
            } else if stroke.points.count == 1 {
                let p = geometry.toCanvas(first)
                context.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
            } else {
                context.beginPath(); context.move(to: geometry.toCanvas(first))
                for point in stroke.points.dropFirst() { context.addLine(to: geometry.toCanvas(point)) }
                context.strokePath()
            }
            context.restoreGState()
        }
        context.restoreGState()
        if let pointer = scene.pointer {
            let p = geometry.toCanvas(pointer)
            let radius = bounds.width * 0.009
            context.setFillColor(CGColor(red: 0.18, green: 0.49, blue: 1, alpha: 0.22))
            context.fillEllipse(in: CGRect(x: p.x - radius * 1.7, y: p.y - radius * 1.7, width: radius * 3.4, height: radius * 3.4))
            context.setFillColor(CGColor(red: 0.20, green: 0.52, blue: 1, alpha: 1))
            context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(max(1, bounds.width / 960))
            context.addEllipse(in: CGRect(x: p.x - radius / 2, y: p.y - radius / 2, width: radius, height: radius))
            context.drawPath(using: .fillStroke)
        }
        context.restoreGState()
    }
    private static func drawShape(_ shape: AnnotationShape, stroke: Stroke, geometry: PageGeometry, context: CGContext) {
        guard let first = stroke.points.first else { return }
        let a = geometry.toCanvas(first), b = geometry.toCanvas(stroke.points.last ?? first)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch shape {
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .line, .arrow:
            context.beginPath(); context.move(to: a); context.addLine(to: b)
            if shape == .arrow {
                let length: CGFloat = max(12, CGFloat(stroke.width) * geometry.pageRect.width * 5)
                let angle: Double = Darwin.atan2(Double(b.y - a.y), Double(b.x - a.x))
                for delta in [-Double.pi / 6, Double.pi / 6] {
                    context.move(to: b)
                    context.addLine(to: CGPoint(x: b.x - CGFloat(Darwin.cos(angle + delta)) * length,
                                               y: b.y - CGFloat(Darwin.sin(angle + delta)) * length))
                }
            }
            context.strokePath()
        case .text:
            let font = CTFontCreateWithName("Helvetica" as CFString, max(8, CGFloat(stroke.width) * geometry.pageRect.width * 5), nil)
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color(stroke.color)] as CFDictionary
            let text = CFAttributedStringCreate(nil, (stroke.text ?? "Text") as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(text)
            context.textMatrix = .identity; context.textPosition = a
            CTLineDraw(line, context)
        }
    }
    public static func image(artwork: PageArtwork, scene: Scene, size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(artwork: artwork, scene: scene, in: context, bounds: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
