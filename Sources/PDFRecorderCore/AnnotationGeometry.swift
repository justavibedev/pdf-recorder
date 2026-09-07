import CoreGraphics
import CoreText
import Foundation

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
        let width = max(tolerance, stroke.width * geometry.pageRect.width / 2)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch shape(of: stroke) {
        case .rectangle:
            return rect.insetBy(dx: -width, dy: -width).contains(point) && !rect.insetBy(dx: width, dy: width).contains(point)
        case .ellipse:
            guard rect.width > 0, rect.height > 0 else { return distance(point, to: a, end: b) <= width }
            let x = (point.x - rect.midX) / (rect.width / 2), y = (point.y - rect.midY) / (rect.height / 2)
            return abs(hypot(x, y) - 1) * min(rect.width, rect.height) / 2 <= width
        case .text:
            let fontSize = max(8, stroke.width * geometry.pageRect.width * 5)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let value = CFAttributedStringCreate(nil, (stroke.text ?? "Text") as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(value)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            return CGRect(x: a.x, y: a.y - descent, width: textWidth, height: ascent + descent).insetBy(dx: -width, dy: -width).contains(point)
        case .line, .arrow:
            if distance(point, to: a, end: b) <= width { return true }
            if shape(of: stroke) == .arrow {
                let length = max(12, stroke.width * geometry.pageRect.width * 5)
                let angle = atan2(b.y - a.y, b.x - a.x)
                return [-Double.pi / 6, Double.pi / 6].contains { delta in
                    distance(point, to: b, end: CGPoint(x: b.x - cos(angle + delta) * length, y: b.y - sin(angle + delta) * length)) <= width
                }
            }
            return false
        case nil:
            return points.contains { hypot($0.x - point.x, $0.y - point.y) <= width }
                || zip(points, points.dropFirst()).contains { distance(point, to: $0.0, end: $0.1) <= width }
        }
    }
    private static func distance(_ point: CGPoint, to a: CGPoint, end b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, denominator = dx * dx + dy * dy
        let t = denominator == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}
