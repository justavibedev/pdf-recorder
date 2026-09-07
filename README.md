# PDF Recorder

A native, offline macOS app for recording PDF presentations one page at a time.

Prepare notes, rehearse, then record your voice, pointer, pen, highlights, and zoom/pan. Keep multiple takes per page, choose your favorites, and export one MP4 or an audio study file. Built for students, free for everyone.

**0.3 development preview:** builds as a native universal Mac app. Core and synthetic media tests run locally and in CI. Live microphone, UI, and long-session acceptance checks remain open. This is not yet a notarized public release.

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

- **Refine your takes.** Trim beginnings and endings without changing the source.
  Use a waveform with silence/clipping feedback, label and favorite takes, mark
  corrections, loop A–B sections, and compare takes at the same position.
- **Choose what you share.** Auditioning a take never changes the export selection.
  Use **Use in Export** when ready. Export included pages, the current page,
  a custom range, or the current PDF chapter, together or as separate files.
- **Better audio.** An explicit **Check Microphone** action reports silence,
  quiet input, and clipping without saving audio. Optional speech-level matching,
  per-take volume, and short edge fades apply to playback and export.
- **Present with confidence.** Write private page notes, run a teleprompter with
  an adjustable reading guide, and show a clean audience canvas on another display.
  The presenter keeps notes, controls, timing, and next-page preview.
- **Rehearse without recording.** Use drawing tools and custom timing targets.
  Review actual versus planned time, repeated page visits, and total overruns;
  keep rehearsal history and export Markdown reports. Practice never starts a mic.
- **Find what matters.** Search titles, notes, and PDF text; select/copy text and
  see exact matches. Navigate the document outline and printed page labels.
  Opt into offline OCR for scanned pages without changing the source PDF.
- **Explain visually.** Adjust pen width and opacity, draw arrows and shapes,
  add text labels, erase, undo, redo, or clear marks in one undoable action.
  PDF vectors render sharply at the current zoom and output resolution.
- **Continue later.** Recent and pinned projects show previews and progress;
  reopen at your last page and viewport. Microphone, countdown, playback speed,
  notes size, larger controls, and sidebar settings persist between launches.
- **Recover your work.** Deleted takes go to project Trash. The Storage & Recovery
  center shows disk use, unused takes, unfinished recordings, unavailable files,
  and restorable snapshots. Save As can rescue notes from a read-only project.
- **Fit your workspace.** Collapse either sidebar, widen notes, use compact layouts,
  switch tools from the keyboard, or find actions with **⌘K**. Canvas text is
  exposed to VoiceOver, and recording-state changes are announced.

Notes and review metadata autosave inside the project. Notes, OCR text, and
rehearsal reports are included when sharing the project package; private notes
and search/selection overlays never enter audio or video exports.

## A simple workflow

1. **Open a PDF** using **⌘O**, drag and drop, or your recent-project library.
2. **Prepare.** Add notes and targets. Optionally recognize scanned text, practice,
   or open the audience display from **Presenting**.
3. **Record.** Select a microphone in **Recording & audio**. An optional microphone
   check saves no audio. Press **Record Page**; capture begins after your countdown.
4. **Review.** Stop to autosave. Listen to takes, trim the kept range, add review
   markers, and compare A/B. Choose **Use in Export** for the version you want.
5. **Save and share.** Save Project makes a portable `.pdfrecorder` package.
   Export MP4 or M4A, choose pages and quality, and review included/skipped counts.
   Batch output appears only when every page succeeds.

Page navigation locks during recording. Pausing freezes the scene and excludes
pause time. Every new take starts with clean app-created marks and the current
viewport. Your earlier takes and source PDF remain intact.

## Principles

- Local files, no account, no server, no analytics.
- No subscriptions, watermarks, or artificial recording limits.
- Native SwiftUI/AppKit, PDFKit, AVFoundation, and Vision; no third-party runtime dependencies.
- Page-level retakes so one mistake never means starting the whole presentation over.

## Requirements

macOS 14 or later. Build with Xcode 15.4 or later. Apple Silicon and Intel are targeted.

The app uses Apple’s installed frameworks rather than bundling a browser,
external video toolchain, or OCR service. Build size excludes your PDFs and
recordings; see the validation ledger for the measured local build.

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
| Search commands | ⌘K |
| Find in PDF and notes | ⌘F |
| Project library | ⌘⇧O |
| Toggle page sidebar / inspector | ⌘⌥1 / ⌘⌥2 |
| Audience display | ⌘⇧D |
| Hold / resume teleprompter | ⌘⇧Space |

With the canvas focused, arrow keys navigate and Space pauses/resumes recording
or playback, and ends practice. Escape cancels the countdown. Pinch zooms;
scroll pans; ⌘-scroll also zooms. Canvas tool keys are P (pen), H (highlighter), V (pointer), E (eraser),
M (pan), S (select text), L (line), A (arrow), R (rectangle), O (ellipse), and
T (text label). +/− zoom; 0 fits the page. Page Up/Down supports presentation
clickers. These keys do not intercept typing in notes. Standard text Undo/Redo
stays available when editing text; the canvas handles annotation Undo/Redo.

## Design and efficiency

The interface uses native SwiftUI/AppKit controls with **SwiftUI adaptations of
Rare UI's Folder Component and Step Player**, under its MIT license. It does not
embed React, shadcn, or a web view. See [third-party notices](THIRD_PARTY_NOTICES.md).
Animations respect Reduce Motion.

Microphone sample counts drive the visual timeline. Audio streams to disk,
recovery events append incrementally, and idle timers stop. A bounded set of
scene checkpoints accelerates backward seeking; export reads events in chunks
one page at a time. Waveform analysis and export preparation run off the UI thread.
PDF backgrounds cache the visible viewport at output resolution, with bounded
caches for editor and audience displays. OCR uses Apple Vision on-device and
caches each completed page with a source fingerprint.

Prepared playback audio is reused between listens and A/B comparisons. Its local
disk cache retains at most three clips within 512 MiB, except that a single larger
clip may be retained alone. Clear it from **Storage & Recovery**; source recordings
are unaffected.

Recording and export prevent idle system sleep, then release that protection
when finished or cancelled. This does not override deliberate sleep or shutdown.

## Privacy and storage

The app has no network code, accounts, analytics, or telemetry. It requests
microphone permission only after you explicitly start a recording or microphone
check. A check monitors levels without creating an audio file. Recording is
limited to the PDF canvas and your microphone.

Until you choose Save Project, work is autosaved under
`~/Library/Application Support/PDF Recorder/Recovery/`. Unsaved projects appear
on the next launch. A completed take is kept even if a later recording fails.
An interrupted take can recover its readable audio and last saved gestures.

Project packages contain unencrypted microphone audio, notes, and optional OCR
text, even when the source PDF is encrypted. Recent-project previews are not
created for encrypted PDFs. Passwords are never saved. Raw audio uses approximately **346 MB
per hour**; take history increases storage. No artificial duration limit is imposed,
but available disk space and memory still apply. Trash retains media until you
explicitly delete it permanently. Snapshots share media files and prevent purging
takes they still reference.

## Validation and contributing

See [validation and the live checklist](docs/VALIDATION.md),
[project format](docs/PROJECT_FORMAT.md), and [contributing](CONTRIBUTING.md).
Synthetic media tests do not use the microphone. They verify MP4 dimensions,
frame rate, codec, duration, frame agreement with the renderer, and audio-only
AAC export. Tests also cover search, bookmarks, export exclusions, countdown
cancellation, and upgrading projects from formats v1/v2 to v3. Headless controller tests use
fake playback and disabled device discovery; they never launch the app or use
a microphone. See the [0.3 implementation ledger](docs/IMPLEMENTATION-0.3.md).

Webcam, system audio, cloud sharing, transcription, and continuous recording
across pages are outside the first release.

## License

MIT. See [LICENSE](LICENSE).
