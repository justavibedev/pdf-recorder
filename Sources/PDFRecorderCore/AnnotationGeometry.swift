import CoreGraphics
import CoreText
import Foundation
import Darwin

public enum AnnotationGeometry {
    public static func shape(of stroke: Stroke) -> AnnotationShape? {
        if let shape = stroke.shape { return shape }
        return AnnotationShape(rawValue: stroke.tool.rawValue)
    }
    /// Shared hit testing includes the visible shape edges and text, not the invisible drag diagonal.
    public static func hitTest(_ stroke: Stroke, at point: CGPoint, geometry: PageGeometry, tolerance: CGFloat = 10) -> Bool {
        guard let first = stroke.points.first else { return false }
        let points = stroke.points.map(geometry.toCanvas)
        let a = geometry.toCanvas(first), b = points.last ?? a
        let width: CGFloat = max(tolerance, CGFloat(stroke.width) * geometry.pageRect.width / 2)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch shape(of: stroke) {
        case .rectangle:
            return rect.insetBy(dx: -width, dy: -width).contains(point) && !rect.insetBy(dx: width, dy: width).contains(point)
        case .ellipse:
            guard rect.width > 0, rect.height > 0 else { return distance(point, to: a, end: b) <= width }
            let x: CGFloat = (point.x - rect.midX) / (rect.width / 2)
            let y: CGFloat = (point.y - rect.midY) / (rect.height / 2)
            let unitRadius: CGFloat = (x * x + y * y).squareRoot()
            let edgeDistance: CGFloat = abs(unitRadius - 1) * min(rect.width, rect.height) / 2
            return edgeDistance <= width
        case .text:
            let fontSize: CGFloat = max(8, CGFloat(stroke.width) * geometry.pageRect.width * 5)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let value = CFAttributedStringCreate(nil, (stroke.text ?? "Text") as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(value)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            return CGRect(x: a.x, y: a.y - descent, width: CGFloat(textWidth), height: ascent + descent).insetBy(dx: -width, dy: -width).contains(point)
        case .line, .arrow:
            if distance(point, to: a, end: b) <= width { return true }
            if shape(of: stroke) == .arrow {
                let length: CGFloat = max(12, CGFloat(stroke.width) * geometry.pageRect.width * 5)
                let angle: Double = Darwin.atan2(Double(b.y - a.y), Double(b.x - a.x))
                return [-Double.pi / 6, Double.pi / 6].contains { delta in
                    let end = CGPoint(x: b.x - CGFloat(Darwin.cos(angle + delta)) * length,
                                      y: b.y - CGFloat(Darwin.sin(angle + delta)) * length)
                    return distance(point, to: b, end: end) <= width
                }
            }
            return false
        case nil:
            return points.contains { distance(point, to: $0, end: $0) <= width }
                || zip(points, points.dropFirst()).contains { distance(point, to: $0.0, end: $0.1) <= width }
        }
    }
    private static func distance(_ point: CGPoint, to a: CGPoint, end b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, denominator = dx * dx + dy * dy
        let t: CGFloat = denominator == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator))
        let x = point.x - (a.x + t * dx), y = point.y - (a.y + t * dy)
        return (x * x + y * y).squareRoot()
    }
}
