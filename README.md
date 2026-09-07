# PDF Recorder

A native, offline macOS app for recording PDF presentations one page at a time.

Record your voice, pointer, pen, highlights, and zoom/pan. Keep multiple takes per page, choose your favorites, and export one MP4. Built for students, free for everyone.

**Development status:** the first release is being implemented. This repository is not yet a published, notarized release.

## Principles

- Local files, no account, no server, no analytics.
- No subscriptions, watermarks, or artificial recording limits.
- Native SwiftUI/AppKit, PDFKit, and AVFoundation; no third-party runtime dependencies.
- Page-level retakes so one mistake never means starting the whole presentation over.

## Requirements

macOS 14 or later. Build with Xcode 15 or later. Apple Silicon and Intel are targeted.

## Development

Open `PDFRecorder.xcodeproj` and run the `PDFRecorder` scheme. The checked-in project is generated from `project.yml` using XcodeGen; contributors only need Xcode to build it.

```sh
swift test
./scripts/build.sh
```

Detailed workflow, project format, and validation instructions will be added with the implementation.

## License

MIT. See [LICENSE](LICENSE).
