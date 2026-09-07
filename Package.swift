// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFRecorder",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PDFRecorderCore", targets: ["PDFRecorderCore"])],
    targets: [
        .target(name: "PDFRecorderCore"),
        .testTarget(name: "PDFRecorderCoreTests", dependencies: ["PDFRecorderCore"])
    ]
)
