import Foundation
import PDFKit
import Vision
import CryptoKit

/// Rotation-corrected unit coordinates, matching recorded pointer and annotation coordinates.
public struct PageTextRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public var rect: CGRect { CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) }
    public init(_ rect: CGRect) { x = Double(rect.minX); y = Double(rect.minY); width = Double(rect.width); height = Double(rect.height) }
}

public struct PageReadingContent: Codable, Equatable, Sendable {
    public var text: String
    /// One rectangle per UTF-16 code unit. Whitespace without geometry has a zero rectangle.
    public var characterBounds: [PageTextRect]
    public init(text: String, characterBounds: [PageTextRect]) { self.text = text; self.characterBounds = characterBounds }
}

public struct PDFOutlineItem: Identifiable, Equatable, Sendable {
    public let id: String, title: String
    public let page: Int, depth: Int
    public init(id: String, title: String, page: Int, depth: Int) { self.id = id; self.title = title; self.page = page; self.depth = depth }
}

public enum PDFReading {
    public static func displaySize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .cropBox)
        return abs(page.rotation % 180) == 90 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }
    public static func normalized(_ rect: CGRect, on page: PDFPage) -> PageTextRect {
        let size = displaySize(of: page)
        let displayed = rect.applying(page.transform(for: .cropBox))
        return PageTextRect(CGRect(x: displayed.minX / size.width, y: displayed.minY / size.height,
                                   width: displayed.width / size.width, height: displayed.height / size.height))
    }
    public static func pagePoint(_ normalized: Point, on page: PDFPage) -> CGPoint {
        let size = displaySize(of: page)
        return CGPoint(x: CGFloat(normalized.x) * size.width, y: CGFloat(normalized.y) * size.height).applying(page.transform(for: .cropBox).inverted())
    }
    public static func content(of page: PDFPage) -> PageReadingContent {
        let text = page.string ?? ""
        let count = min((text as NSString).length, page.numberOfCharacters)
        return PageReadingContent(text: text, characterBounds: (0..<count).map { index in
            let rect = page.characterBounds(at: index)
            return rect.isEmpty || rect.isNull || rect.isInfinite ? PageTextRect(.zero) : normalized(rect, on: page)
        })
    }
    public static func label(for page: PDFPage, index: Int) -> String {
        let label = page.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? String(index + 1) : label
    }
    public static func outline(in document: PDFDocument) -> [PDFOutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        var result: [PDFOutlineItem] = []
        func visit(_ parent: PDFOutline, path: String, depth: Int) {
            for index in 0..<parent.numberOfChildren {
                guard let item = parent.child(at: index) else { continue }
                let id = "\(path).\(index)"
                if let page = (item.destination ?? (item.action as? PDFActionGoTo)?.destination)?.page {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound {
                        result.append(PDFOutlineItem(id: id, title: item.label ?? "Page \(pageIndex + 1)", page: pageIndex, depth: depth))
                    }
                }
                visit(item, path: id, depth: depth + 1)
            }
        }
        visit(root, path: "outline", depth: 0)
        return result
    }
    public static func matches(query: String, in content: PageReadingContent) -> [PageTextRect] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let text = content.text as NSString
        var range = NSRange(location: 0, length: text.length), rectangles: [PageTextRect] = []
        while range.length > 0 {
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard found.location != NSNotFound else { break }
            for index in found.location..<min(NSMaxRange(found), content.characterBounds.count) {
                let box = content.characterBounds[index]
                if !box.rect.isEmpty && !rectangles.contains(box) { rectangles.append(box) }
            }
            range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        return rectangles
    }
    /// Select complete characters in a rectangle. Native PDF drag-selection uses PDFKit's reading order instead.
    public static func selectedText(in content: PageReadingContent, rectangle: CGRect) -> (text: String, boxes: [PageTextRect]) {
        let utf16 = Array(content.text.utf16)
        var selected: [UInt16] = [], boxes: [PageTextRect] = []
        for index in 0..<min(utf16.count, content.characterBounds.count) {
            let bounds = content.characterBounds[index]
            if !bounds.rect.isEmpty && rectangle.intersects(bounds.rect) {
                selected.append(utf16[index]); boxes.append(bounds)
            } else if !selected.isEmpty && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(utf16[index]) ?? " ") {
                selected.append(utf16[index])
            }
        }
        return (String(decoding: selected, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines), boxes)
    }
}

public enum OCRReading {
    private struct Cache: Codable { var version = 1; var fingerprint: String; var pages: [Int: PageReadingContent] }
    public static func loadCache(pdfURL: URL, cacheDirectory: URL) throws -> [Int: PageReadingContent] {
        let url = cacheDirectory.appendingPathComponent("ocr.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: url))
        guard cache.version == 1, cache.fingerprint == (try fingerprint(pdfURL)) else { return [:] }
        return cache.pages
    }
    /// Runs on the caller's worker task. Vision handles only local pixels and never modifies the source PDF.
    /// The caller owns cancellation; each page is committed atomically so completed OCR survives interruption.
    public static func recognize(pdfURL: URL, password: String?, cacheDirectory: URL,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> [Int: PageReadingContent] {
        guard let document = PDFDocument(url: pdfURL) else { throw RecorderError.message("The PDF could not be read for text recognition.") }
        if document.isLocked { _ = document.unlock(withPassword: password ?? "") }
        guard !document.isLocked else { throw RecorderError.message("Unlock this PDF before recognizing text.") }
        let fingerprint = try fingerprint(pdfURL)
        var pages = (try? loadCache(pdfURL: pdfURL, cacheDirectory: cacheDirectory)) ?? [:]
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if pages[index] == nil, let page = document.page(at: index) {
                if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages[index] = PDFReading.content(of: page) }
                else {
                    let artwork = try PageArtwork(page: page, maximumDimension: 2400)
                    pages[index] = try recognize(image: artwork.image)
                }
                try Task.checkCancellation()
                let data = try JSONEncoder().encode(Cache(fingerprint: fingerprint, pages: pages))
                try data.write(to: cacheDirectory.appendingPathComponent("ocr.json"), options: .atomic)
            }
            progress(Double(index + 1) / Double(max(1, document.pageCount)))
        }
        return pages
    }
    public static func recognize(image: CGImage) throws -> PageReadingContent {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        var content = PageReadingContent(text: "", characterBounds: [])
        let observations = (request.results ?? []).sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.boundingBox.height, b.boundingBox.height) / 2 { return a.boundingBox.midY > b.boundingBox.midY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            if !content.text.isEmpty { content.text += "\n"; content.characterBounds.append(PageTextRect(.zero)) }
            content.text += candidate.string
            for index in candidate.string.indices {
                let next = candidate.string.index(after: index), range = index..<next
                let bounds = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                for _ in candidate.string[range].utf16 { content.characterBounds.append(PageTextRect(bounds)) }
            }
        }
        return content
    }
    private static func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
