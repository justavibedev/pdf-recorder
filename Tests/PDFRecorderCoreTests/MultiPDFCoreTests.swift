import XCTest
import PDFKit
import AVFoundation
@testable import PDFRecorderCore

final class MultiPDFCoreTests: XCTestCase {
    private func pdf(_ page: Int? = nil, named name: String, in directory: URL) throws -> URL {
        let fixture = fixturePDF()
        let document: PDFDocument
        if let page {
            document = PDFDocument()
            document.insert(try XCTUnwrap(fixture.page(at: page)?.copy() as? PDFPage), at: 0)
        } else { document = fixture }
        let url = directory.appendingPathComponent(name + ".pdf")
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        return url
    }
    private func project(in directory: URL) throws -> (URL, ProjectManifest) {
        let source = try pdf(named: "Original", in: directory)
        let root = directory.appendingPathComponent("Course.pdfrecorder")
        return (root, try ProjectStore.create(at: root, source: source, title: "Course", pageCount: 3))
    }
    private func addTake(to page: Int, manifest: ProjectManifest, at root: URL) throws -> ProjectManifest {
        var take = Take(duration: 0.2)
        take.createdAt = Date(timeIntervalSince1970: 1_000)
        try writeAudio(at: ProjectStore.prepare(take, at: root), duration: 0.2)
        return try ProjectStore.commit(take, events: [.init(time: 0.05, action: .pointer(Point(0.2, 0.7)))], page: page, manifest: manifest, at: root)
    }
    private func contents(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            result[name] = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? Data(contentsOf: url) : Data()
        }
        return result
    }

    func testLegacyVersionsKeepSingleDocumentIdentityAndTakeSelection() throws {
        for version in 1...3 {
            let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
            let (root, initial) = try project(in: temporary)
            var legacy = try addTake(to: 1, manifest: initial, at: root)
            legacy.version = version
            legacy.pages[1].notes = "Existing study notes"
            try ProjectStore.save(legacy, at: root)
            let loaded = try ProjectStore.load(at: root)
            XCTAssertEqual(loaded.version, 4)
            XCTAssertNil(loaded.documents)
            XCTAssertEqual(loaded.pages, legacy.pages)
            XCTAssertEqual(loaded.pdfDocuments, [.init(id: legacy.id, title: "Course", path: "source.pdf", pageCount: 3)])
            XCTAssertEqual(loaded.pageRange(for: legacy.id), 0..<3)
            XCTAssertEqual(loaded.document(containing: 2)?.id, legacy.id)
            XCTAssertEqual(loaded.localPageIndex(globalPage: 2), 2)
            XCTAssertNil(loaded.document(containing: -1)); XCTAssertNil(loaded.document(containing: 3))
            XCTAssertNil(loaded.localPageIndex(globalPage: 3)); XCTAssertNil(loaded.pageRange(for: UUID()))
            try ProjectStore.save(loaded, at: root)
            XCTAssertEqual(try ProjectStore.load(at: root), loaded)
        }
    }

    func testAppendPreservesBytesStablePageRangesAndPortableSaveCopy() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        var recorded = try addTake(to: 2, manifest: initial, at: root)
        recorded.pages[2].title = "Final topic"; recorded.pages[2].notes = "Keep my notes"
        try ProjectStore.save(recorded, at: root)
        let landscape = try pdf(1, named: "Landscape", in: temporary), rotated = try pdf(2, named: "Rotated", in: temporary)
        let before = try contents(root)
        let appended = try ProjectStore.addPDFs([.init(source: landscape, title: "Landscape", pageCount: 1),
                                               .init(source: rotated, title: "Rotated", pageCount: 1)], manifest: recorded, at: root)
        XCTAssertEqual(Array(appended.pages.prefix(3)), recorded.pages)
        XCTAssertEqual(appended.pages.count, 5)
        XCTAssertEqual(appended.pdfDocuments.map(\.title), ["Course", "Landscape", "Rotated"])
        XCTAssertEqual(appended.pdfDocuments.map(\.pageCount), [3, 1, 1])
        XCTAssertEqual(appended.pdfDocuments.map { appended.pageRange(for: $0.id) }, [0..<3, 3..<4, 4..<5])
        XCTAssertEqual((0..<5).map { appended.localPageIndex(globalPage: $0) }, [0, 1, 2, 0, 0])
        XCTAssertEqual(appended.document(containing: 3)?.id, appended.pdfDocuments[1].id)
        for (name, data) in before where name != "manifest.json" { XCTAssertEqual(try contents(root)[name], data, name) }
        for (document, source) in zip(appended.pdfDocuments.dropFirst(), [landscape, rotated]) {
            XCTAssertEqual(try Data(contentsOf: ProjectStore.location(document.path, in: root)), try Data(contentsOf: source))
        }
        XCTAssertEqual(try ProjectStore.load(at: root), appended)
        // Appending to an existing documents directory is supported, including the same input PDF.
        let again = try ProjectStore.addPDFs([.init(source: landscape, title: "Appendix", pageCount: 1)], manifest: appended, at: root)
        XCTAssertEqual(again.pdfDocuments.count, 4)
        XCTAssertEqual(Set(again.pdfDocuments.map(\.path)).count, 4)
        let copy = temporary.appendingPathComponent("Portable.pdfrecorder")
        try ProjectStore.saveCopy(from: root, to: copy, manifest: again)
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(try ProjectStore.load(at: copy), again)
        XCTAssertEqual(try ProjectStore.events(for: XCTUnwrap(again.pages[2].selectedTake), at: copy).count, 1)
    }

    func testBatchAppendFailureRollsBackEveryStagedFileAndManifest() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let valid = try pdf(1, named: "Valid", in: temporary)
        let broken = temporary.appendingPathComponent("Broken.pdf")
        try Data("Not a PDF".utf8).write(to: broken)
        let before = try contents(root)
        for failing in [PDFImport(source: broken, title: "Broken", pageCount: 1),
                        PDFImport(source: valid, title: "Wrong count", pageCount: 2)] {
            XCTAssertThrowsError(try ProjectStore.addPDFs([.init(source: valid, title: "Valid", pageCount: 1), failing], manifest: initial, at: root))
            XCTAssertEqual(try contents(root), before)
            XCTAssertEqual(try ProjectStore.load(at: root), initial)
        }
        XCTAssertEqual(try ProjectStore.addPDFs([], manifest: initial, at: root), initial)
    }

    func testManifestRejectsDocumentTraversalDuplicatesAndCountMismatch() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let extra = try pdf(1, named: "Extra", in: temporary)
        let valid = try ProjectStore.addPDFs([.init(source: extra, title: "Extra", pageCount: 1)], manifest: initial, at: root)
        let changes: [(inout ProjectManifest) -> Void] = [
            { $0.documents = [] },
            { $0.documents?[0].id = UUID() },
            { $0.documents?[1].id = $0.id },
            { $0.documents?[1].path = "../Extra.pdf" },
            { $0.documents?[1].path = "source.pdf" },
            { $0.documents?[1].pageCount = 0 },
            { $0.documents?[1].pageCount = Int.max },
            { $0.pages.append(PageRecord()) }
        ]
        for change in changes {
            var invalid = valid; change(&invalid)
            try ProjectStore.save(invalid, at: root)
            XCTAssertThrowsError(try ProjectStore.load(at: root))
        }
        try ProjectStore.save(valid, at: root)
        let additional = try ProjectStore.location(valid.pdfDocuments[1].path, in: root)
        try FileManager.default.removeItem(at: additional)
        try FileManager.default.createSymbolicLink(at: additional, withDestinationURL: extra)
        XCTAssertThrowsError(try ProjectStore.load(at: root))
    }

    func testManifestWriteFailureRemovesNewlyPublishedPDFFolders() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let extra = try pdf(1, named: "Extra", in: temporary)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        // Force failure at the final atomic write, after staged folders are moved.
        // This is deterministic even when tests run with elevated file permissions.
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        try original.write(to: manifestURL.appendingPathComponent("existing-content"))
        let before = try contents(root)
        XCTAssertThrowsError(try ProjectStore.addPDFs([.init(source: extra, title: "Extra", pageCount: 1)], manifest: initial, at: root))
        XCTAssertEqual(try contents(root), before)
    }

    func testEncryptedAppendRequiresPasswordAndKeepsOriginalEncryptedBytes() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let encrypted = temporary.appendingPathComponent("Private.pdf")
        let document = fixturePDF(), password = "in-memory-test-password"
        XCTAssertTrue(document.write(to: encrypted, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: encrypted)).isLocked)
        let original = try Data(contentsOf: encrypted), before = try contents(root)
        XCTAssertThrowsError(try ProjectStore.addPDFs([.init(source: encrypted, title: "Private", pageCount: 3, password: "wrong")], manifest: initial, at: root))
        XCTAssertEqual(try contents(root), before)
        let updated = try ProjectStore.addPDFs([.init(source: encrypted, title: "Private", pageCount: 3, password: password)], manifest: initial, at: root)
        let copied = try ProjectStore.location(updated.pdfDocuments[1].path, in: root)
        XCTAssertEqual(try Data(contentsOf: copied), original)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: copied)).isLocked)
        XCTAssertFalse(String(decoding: try Data(contentsOf: root.appendingPathComponent("manifest.json")), as: UTF8.self).contains(password))
        XCTAssertEqual(try ProjectStore.load(at: root), updated)
    }

    func testOldSnapshotPreservesAppendedDocumentsNotesAndTakes() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let recorded = try addTake(to: 0, manifest: initial, at: root)
        var old = recorded; old.version = 3
        let snapshot = try ProjectRecovery.snapshot(old, reason: "Before append", at: root)
        let extra = try pdf(1, named: "Extra", in: temporary)
        var current = try ProjectStore.addPDFs([.init(source: extra, title: "Extra", pageCount: 1)], manifest: recorded, at: root)
        current = try addTake(to: 0, manifest: current, at: root)
        let newPrefixTake = try XCTUnwrap(current.pages[0].selectedTakeID)
        current = try addTake(to: 3, manifest: current, at: root)
        current.pages[3].notes = "Appended notes survive restore"
        try ProjectStore.save(current, at: root)
        let restored = try ProjectRecovery.restoreSnapshot(snapshot, current: current, at: root)
        XCTAssertEqual(restored.pages[0], recorded.pages[0])
        XCTAssertEqual(restored.pages[3], current.pages[3])
        XCTAssertEqual(restored.pdfDocuments, current.pdfDocuments)
        XCTAssertEqual(try ProjectRecovery.trash(at: root).map(\.id), [newPrefixTake])
        XCTAssertEqual(try ProjectStore.load(at: root), restored)
        var mismatched = snapshot
        mismatched.manifest.documents = [.init(id: recorded.id, title: "Different count", path: "source.pdf", pageCount: 2)]
        mismatched.manifest.pages.removeLast()
        XCTAssertThrowsError(try ProjectRecovery.restoreSnapshot(mismatched, current: restored, at: root))
        XCTAssertEqual(try ProjectStore.load(at: root), restored)
    }

    func testAppendedDocumentsDoNotRemapInterruptedRecordingPage() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let (root, initial) = try project(in: temporary)
        let take = Take(duration: 0.2)
        try writeAudio(at: ProjectStore.prepare(take, at: root), duration: 0.2)
        try ProjectStore.journal(.init(page: 2, take: take, events: []), at: root)
        let extra = try pdf(1, named: "Extra", in: temporary)
        let appended = try ProjectStore.addPDFs([.init(source: extra, title: "Extra", pageCount: 1)], manifest: initial, at: root)
        let recovered = try ProjectStore.recover(at: root, manifest: appended)
        XCTAssertEqual(recovered.pages[2].selectedTakeID, take.id)
        XCTAssertTrue(recovered.pages[3].takes.isEmpty)
        XCTAssertEqual(recovered.document(containing: 2)?.id, initial.id)
        XCTAssertEqual(try ProjectStore.load(at: root), recovered)
    }

    func testMP4UsesEachPDFLocalPageGeometryAndCallerOrder() async throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        let sources = try [pdf(0, named: "Portrait", in: temporary), pdf(1, named: "Landscape", in: temporary), pdf(2, named: "Rotated", in: temporary)]
        let password = "export-memory-password"
        let encrypted = try XCTUnwrap(PDFDocument(url: sources[1]))
        XCTAssertTrue(encrypted.write(to: sources[1], withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]))
        let audio = temporary.appendingPathComponent("synthetic.caf")
        try writeAudio(at: audio, duration: 0.2)
        let sourceOrder = [0, 1, 2, 0], globalPages = [0, 3, 4, 0]
        let items = sourceOrder.enumerated().map { index, source in
            ExportItem(page: globalPages[index], take: Take(duration: 0.2), events: [], audioURL: audio,
                       pdfURL: sources[source], pdfPage: 0, pdfPassword: source == 1 ? password : nil)
        }
        let output = temporary.appendingPathComponent("Multiple PDFs.mp4")
        try await VideoExporter.export(pdfURL: temporary.appendingPathComponent("unused-fallback.pdf"), password: nil,
                                       items: items, to: output, width: 640, height: 360, progress: { _ in })
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.8, accuracy: 0.001)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (index, source) in sourceOrder.enumerated() {
            let frame = try await generator.image(at: CMTime(seconds: Double(index) * 0.2 + 0.1, preferredTimescale: 30))
            let referencePDF = try XCTUnwrap(PDFDocument(url: sources[source]))
            if referencePDF.isLocked { XCTAssertTrue(referencePDF.unlock(withPassword: password)) }
            let artwork = try PageArtwork(page: XCTUnwrap(referencePDF.page(at: 0)))
            let expected = try XCTUnwrap(SceneRenderer.image(artwork: artwork, scene: Scene(), size: CGSize(width: 640, height: 360)))
            let referencePixels = pixels(expected), actual = pixels(frame.image)
            let error = zip(referencePixels, actual).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(actual.count)
            XCTAssertLessThan(error, 8, "Frame \(index) used the wrong PDF, page, rotation, or fit geometry")
        }
    }
}
