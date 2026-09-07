import AppKit
import PDFKit

/// All page coordinates use the displayed (rotation-corrected) page: origin bottom-left, range 0...1.
public struct PageGeometry {
    public let canvas: CGRect
    public let pageSize: CGSize
    public let viewport: Viewport
    public var pageRect: CGRect {
        let scale = min(canvas.width / pageSize.width, canvas.height / pageSize.height) * viewport.zoom
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(x: canvas.midX - size.width / 2 + viewport.offset.x * canvas.width,
                      y: canvas.midY - size.height / 2 + viewport.offset.y * canvas.height,
                      width: size.width, height: size.height)
    }
    public init(canvas: CGRect, pageSize: CGSize, viewport: Viewport) {
        self.canvas = canvas; self.pageSize = pageSize; self.viewport = viewport
    }
    public func toCanvas(_ point: Point) -> CGPoint {
        CGPoint(x: pageRect.minX + point.x * pageRect.width, y: pageRect.minY + point.y * pageRect.height)
    }
    public func toPage(_ point: CGPoint) -> Point {
        Point((point.x - pageRect.minX) / pageRect.width, (point.y - pageRect.minY) / pageRect.height)
    }
}

public struct PageArtwork {
    public let image: CGImage
    public let size: CGSize
    public init(page: PDFPage, maximumDimension: CGFloat = 3840) throws {
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
        context.draw(artwork.image, in: rect)
        context.saveGState()
        context.clip(to: rect)
        for stroke in scene.strokes {
            guard let first = stroke.points.first else { continue }
            context.saveGState()
            context.setStrokeColor(color(stroke.color))
            context.setFillColor(color(stroke.color))
            let width = stroke.width * rect.width
            context.setLineWidth(width)
            context.setLineCap(.round); context.setLineJoin(.round)
            if stroke.tool == .highlighter {
                context.setBlendMode(.multiply)
                context.setAlpha(0.36)
            }
            if stroke.points.count == 1 {
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
    public static func image(artwork: PageArtwork, scene: Scene, size: CGSize) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(artwork: artwork, scene: scene, in: context, bounds: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
