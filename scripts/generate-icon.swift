// Rebuild the original app icon with system Core Graphics, without external assets.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Sources/PDFRecorderApp/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: Double(pixels) / 1024, y: Double(pixels) / 1024)
        context.addPath(CGPath(roundedRect: CGRect(x: 48, y: 48, width: 928, height: 928), cornerWidth: 205, cornerHeight: 205, transform: nil))
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.17, green: 0.32, blue: 0.82, alpha: 1),
            CGColor(red: 0.35, green: 0.60, blue: 1, alpha: 1)
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 850, y: 1024), options: [])
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.18))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 259, y: 203, width: 475, height: 619), cornerWidth: 49, cornerHeight: 49, transform: nil))
        context.fillPath(); context.setShadow(offset: .zero, blur: 0)
        context.setStrokeColor(CGColor(red: 0.70, green: 0.79, blue: 0.97, alpha: 1))
        context.setLineWidth(23); context.setLineCap(.round)
        for (y, end) in [(708.0, 632.0), (644.0, 558.0)] {
            context.move(to: CGPoint(x: 352, y: y)); context.addLine(to: CGPoint(x: end, y: y)); context.strokePath()
        }
        context.setStrokeColor(CGColor(red: 0.22, green: 0.44, blue: 0.96, alpha: 1)); context.setLineWidth(25)
        for (x, height) in [(357.0, 60.0), (414.0, 135.0), (471.0, 205.0), (528.0, 110.0), (585.0, 65.0)] {
            context.move(to: CGPoint(x: x, y: 451 - height / 2)); context.addLine(to: CGPoint(x: x, y: 451 + height / 2)); context.strokePath()
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: 576, y: 136, width: 263, height: 263))
        context.setFillColor(CGColor(red: 0.97, green: 0.26, blue: 0.30, alpha: 1)); context.fillEllipse(in: CGRect(x: 598, y: 158, width: 219, height: 219))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: 667, y: 227, width: 81, height: 81))
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
