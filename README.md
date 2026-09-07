# PDF Recorder

A native, offline macOS app for recording PDF presentations one page at a time.

Prepare notes, rehearse, then record your voice, pointer, pen, highlights, and zoom/pan. Keep multiple takes per page, choose your favorites, and export one MP4 or an audio study file. Built for students, free for everyone.

**0.2 development preview:** builds as a native universal Mac app. Core and synthetic media tests run locally and in CI. Live microphone, UI, and long-session acceptance checks remain open. This is not yet a notarized public release.

## What you can do

| Record | Review | Share |
| --- | --- | --- |
| Voice, pointer, pen, and highlighter | Independent take history for every page | One 1080p MP4 |
| Zoom and pan while explaining | Scrub, replay, erase, and undo marks | H.264 video with AAC audio |
| Pause without adding dead time | Choose an earlier take at any time | Portable editable project packages |
| Select a microphone and see its level | Preview selected takes in PDF order | Automatic saving and crash recovery |

PDFs can be scanned, portrait, landscape, rotated, mixed-size, or password-protected.
Existing PDF annotations stay visible. The source file is never changed.

## For students and presenters

- **Private presenter notes and page titles.** Write a script beside each page,
  enlarge the text while presenting, and export your notes as Markdown.
- **Practice without recording.** Rehearse with drawing tools, notes, and a
  per-page timer. Practice never starts the microphone or creates a take.
- **Timing targets.** Plan how long each page should take, see your total planned
  time, and get remaining-time or over-target feedback during practice and recording.
- **Find your place.** Search PDF text, page titles, and notes; bookmark key pages;
  filter recorded or unfinished pages; jump to the next unrecorded page.
  Scanned pages are searchable only if the PDF already contains text; there is no OCR.
- **Recording countdown.** Choose off, three, or five seconds. Cancel before
  capture starts, using the button or Escape while the canvas is focused.
- **Faster revision.** Review at 0.75×–2× speed and jump back or forward ten seconds.
  Export stays at the original recorded speed.
- **Choose what to share.** Exclude pages from combined playback and export while
  keeping their takes, or export AAC audio in an M4A file for listening on the go.
- **Focus mode.** Hide the page sidebar to make more room for your PDF and notes.

Page titles, notes, bookmarks, timing targets, and export choices autosave to the
project. Notes stay out of video and audio exports, but are included in the project
package and an explicitly exported notes document. Playback speed, countdown,
filters, and layout preferences last for the current app session.

## A simple workflow

1. **Open a PDF.** Drop it into the window or press **⌘O**.
2. **Prepare and record.** Add notes in **Notes & Timing**, optionally practice,
   then choose your microphone and press **Record Page**. Capture starts after
   your selected countdown.
3. **Mark what matters.** Point, draw, highlight, pinch to zoom, or scroll to pan.
4. **Keep your best take.** Stop to save. Try another take whenever you need to;
   select the one you want from the take list. Right-click a take to delete it.
5. **Save and export.** Save Project creates a portable `.pdfrecorder` package.
   Export combines selected takes as video or audio, skipping unrecorded and
   excluded pages. The confirmation shows included and skipped counts.

Page navigation locks during recording. Pausing freezes the scene; resume before
drawing or moving again. Starting a take clears app-created marks and keeps the
current zoom/pan. Your earlier takes and the source PDF remain intact.

## Principles

- Local files, no account, no server, no analytics.
- No subscriptions, watermarks, or artificial recording limits.
- Native SwiftUI/AppKit, PDFKit, and AVFoundation; no third-party runtime dependencies.
- Page-level retakes so one mistake never means starting the whole presentation over.

## Requirements

macOS 14 or later. Build with Xcode 15 or later. Apple Silicon and Intel are targeted.

The universal 0.2 development app is approximately **6 MB** (**2 MB** zipped),
excluding your PDFs and recordings. It uses Apple's installed frameworks rather than bundling a
browser or video toolchain. Actual size varies with Xcode and build settings.

## Get the app

Build from source below, or download the **PDF-Recorder-macOS** artifact from a
successful [GitHub Actions run](https://github.com/justavibedev/pdf-recorder/actions).
Artifacts require a GitHub login. Development builds are ad-hoc signed and are
not Apple-notarized; macOS may require approval to open a downloaded build.
There is no public release installer yet.

## Development

Open `PDFRecorder.xcodeproj` and run the `PDFRecorder` scheme. The checked-in project is generated from `project.yml` using XcodeGen; contributors only need Xcode to build it.

```sh
swift test
./scripts/build.sh
```

The app is written to `build/PDF Recorder.app`. The script builds both `arm64`
and `x86_64`. XcodeGen is only needed to regenerate the checked-in project:

```sh
brew install xcodegen
xcodegen generate
```

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open PDF or project | ⌘O |
| Save Project As | ⌘S |
| New take | ⌘⇧R |
| Pause / resume recording | ⌘⇧P |
| Stop and save take | ⌘. |
| Play / pause take | ⌘Space |
| Previous / next page | ⌘← / ⌘→ |
| Undo mark | ⌘Z |
| Start / end practice | ⌘⌥R |
| Show notes / takes | ⌘⇧N |
| Bookmark page | ⌘⇧B |
| Next unrecorded page | ⌘⇧U |
| Toggle focus mode | ⌘⇧F |

With the canvas focused, arrow keys navigate and Space pauses/resumes recording
or playback, and ends practice. Escape cancels the countdown. Pinch zooms;
scroll pans; ⌘-scroll also zooms. These canvas keys do not intercept typing in notes.

## Design and efficiency

The interface uses native SwiftUI/AppKit controls with **SwiftUI adaptations of
Rare UI's Folder Component and Step Player**, under its MIT license. It does not
embed React, shadcn, or a web view. See [third-party notices](THIRD_PARTY_NOTICES.md).
Animations respect Reduce Motion.

Microphone sample counts drive the visual timeline. Audio is streamed to disk,
recovery events are appended incrementally, and idle playback timers stop.
Thumbnails and page artwork have bounded caches. Export processes one PDF page
and one video frame at a time. The PDF is rendered to a cached bitmap up to
3840 pixels on its longest edge; deep zoom can soften text.
PDF text extraction runs in the background only when you search; its text index
is cached for the open document. Audio-only export does not render video frames.

## Privacy and storage

The app has no network code, accounts, analytics, or telemetry. It requests only
microphone permission; recording is limited to the PDF canvas and your microphone.

Until you choose Save Project, work is autosaved under
`~/Library/Application Support/PDF Recorder/Recovery/`. Unsaved projects appear
on the next launch. A completed take is kept even if a later recording fails.
An interrupted take can recover its readable audio and last saved gestures.

Project packages contain unencrypted microphone audio, even when the source PDF
is encrypted. Passwords are never saved. Raw audio uses approximately **346 MB
per hour**; take history increases storage. No artificial duration limit is imposed,
but available disk space and memory still apply.

## Validation and contributing

See [validation and the live checklist](docs/VALIDATION.md),
[project format](docs/PROJECT_FORMAT.md), and [contributing](CONTRIBUTING.md).
Synthetic media tests do not use the microphone. They verify MP4 dimensions,
frame rate, codec, duration, frame agreement with the renderer, and audio-only
AAC export. Tests also cover search, bookmarks, export exclusions, countdown
cancellation, and upgrading projects from format v1 to v2.

Webcam, system audio, cloud sharing, transcription, and continuous recording
across pages are outside the first release.

## License

MIT. See [LICENSE](LICENSE).
