// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFRecorder",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PDFRecorderCore", targets: ["PDFRecorderCore"])],
    targets: [
        .target(name: "PDFRecorderCore"),
        .target(name: "PDFRecorderAppSupport", dependencies: ["PDFRecorderCore"], path: "Sources/PDFRecorderApp",
                exclude: ["PDFRecorderApp.swift", "Assets.xcassets", "Info.plist", "PDFRecorder.entitlements"]),
        .testTarget(name: "PDFRecorderCoreTests", dependencies: ["PDFRecorderCore"]),
        .testTarget(name: "PDFRecorderAppTests", dependencies: ["PDFRecorderAppSupport", "PDFRecorderCore"])
    ]
)
