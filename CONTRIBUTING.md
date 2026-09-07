# Contributing

PDF Recorder is a small native Mac app for students. Contributions that make
recording more reliable, accessible, or easier to understand are welcome.

## Setup

1. Install Xcode 15 or newer and open `PDFRecorder.xcodeproj`.
2. Choose the `PDFRecorder` scheme and run on your Mac.
3. Grant microphone access when you choose **Record Page**.
4. Run `swift test` before submitting a change.

The project has no third-party runtime dependencies. XcodeGen is only needed
when changing the target structure: edit `project.yml`, run `xcodegen generate`,
and commit the generated Xcode project too.

## Structure

- `PDFRecorderCore`: format, timeline, geometry, renderer, persistence, export.
- `PDFRecorderApp`: macOS UI, microphone capture, document and playback state.
- `Tests`: deterministic core tests and a real AVFoundation MP4 smoke test.

Keep the recording, preview, and export renderer consistent. New recorded
actions must have deterministic replay and backward-compatible decoding, or
an explicit project format version change. Changes to file operations should
preserve completed takes on failure.

## Pull requests

Explain the student-facing behavior and include the relevant verification.
For UI changes, include before/after screenshots and check light mode, dark
mode, Reduce Motion, keyboard navigation, and VoiceOver labels. For media
changes, run the checklist in [docs/VALIDATION.md](docs/VALIDATION.md).

Do not add analytics, network calls, online fonts, or services to core workflows.
Discuss new runtime dependencies before introducing them.

By contributing, you agree to license your contribution under the MIT license.
