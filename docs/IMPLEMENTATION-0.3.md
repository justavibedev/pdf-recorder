# 0.3 implementation and verification ledger

All 25 requested improvements have implementations in the native macOS app.
This ledger distinguishes automated evidence from interactive acceptance work.
No application launch, microphone capture, or live audio playback was performed
during agent verification. Hardware and interactive checks remain open in
[VALIDATION.md](VALIDATION.md).

Source paths are relative to `Sources/`. Test suites are under `Tests/`.

| # | Improvement | Implementation and evidence |
|---|---|---|
| 1 | Nondestructive take trimming | `TakeReviewView`, shared audio processing and source-time metadata. Media tests verify unchanged sources, duration and the scene at the first trimmed video frame. Controller tests check trim/playhead/loop bounds. |
| 2 | Waveform timeline | `WaveformTimelineView`; bounded analysis distinguishes synthetic silence, speech and clipping in `MediaFeatureTests`. |
| 3 | Independent preview and A/B | AppModel separates audition IDs from saved export choices. Controller tests verify A/B comparison and explicit selection. |
| 4 | Names, flags and favorites | Take review edits portable metadata. Media tests verify round trips and legacy defaults. |
| 5 | Undo deletion and take trash | `ProjectRecovery` preserves media while journaling metadata. Core and controller tests verify deletion, restoration and snapshot protections. |
| 6 | Explicit microphone check | `MicrophoneRecorder` accepts a nil audio destination for monitoring. User-only check controls expose the actual device and signal feedback. Synthetic feedback tests run without hardware; physical behavior remains a manual check. |
| 7 | Volume matching and fades | Shared streaming processing applies per-take gain, optional speech-level matching and edge fades to preview/export. Synthetic tests check matching, lengths and unchanged source bytes. |
| 8 | Recent and pinned projects | `WorkspacePanels`, workspace controller and `WorkspaceStore` provide previews, progress and continuation. Core/controller tests reopen the saved page and viewport. |
| 9 | Remembered preferences | `WorkspaceStore` persists microphone, countdown, playback speed, notes size, controls and layout. Isolated-storage tests verify restoration. |
| 10 | Storage and recovery center | `StorageCenterView` exposes sizes, free space, unused takes, unfinished recordings, missing media, Trash, snapshots and cache cleanup. Workspace tests cover restore, isolation, retry and guarded purge. |
| 11 | A–B loops and markers | Metadata uses source timestamps; waveform and review controls edit/seek them. Controller tests check loop restarts, trim bounds and ended transports using fake playback. |
| 12 | Presets and estimates | `MediaOptions` defines 720p Small upload and 1080p Standard/High quality, bitrate estimates and progress-based ETA. Synthetic exports check dimensions, timing and tracks. |
| 13 | Range and batch export | Export controller supports included/current/range/chapter selection without changing inclusion flags. Workspace tests check parsing, order, cancellation, atomic publication and preservation of existing output. |
| 14 | Presenter display | `PresenterDisplay` shows only the shared canvas on a chosen screen; private notes and next-page preview stay in the presenter view. Multi-display placement and focus need manual acceptance. |
| 15 | Teleprompter | Presenter notes provide speed, font, guide, manual hold and automatic pause coordination. Rehearsal tests check monotonic scroll timing, pauses and reanchoring. |
| 16 | Rehearsal reports | Rehearsal core/controller track visits, actual/planned times, totals and overruns. History, custom targets and trim-aware pacing are tested. Markdown reports are exportable. |
| 17 | Annotation controls | Canvas and shared renderer support widths, opacity, lines/arrows/shapes/text, undo/redo and grouped Clear Marks. Geometry, pixel, timeline and controller tests cover replay and restoration of layer order. |
| 18 | Sleep protection | AppModel balances process activity during recording, checking and export, including pause/stop transitions. A headless controller test checks release on idle. |
| 19 | PDF reading and search | `PageReading` and canvas provide exact match geometry, select/copy, outline and printed labels. Canvas tests check rotation, outlines, labels and native search. |
| 20 | Optional offline OCR | Vision runs after explicit initiation with a fingerprinted per-page cache, preserving the PDF. Tests recognize a synthetic scan and invalidate changed-source caches. |
| 21 | Sharp deep zoom | Shared renderer draws vectors at visible viewport/output resolution. Tests compare PDFKit with crop/rotation/imported annotations and verify detail beyond preview bitmap resolution. |
| 22 | Responsive long-take review | Bounded scene checkpoints, chunked event loading, background preparation and a disk playback cache. Tests cover long seeks, large logs, cache reuse/eviction, source changes, cancellation and recovery of scrubbing after cancelled preparation. |
| 23 | Keyboard workflow | Searchable commands, tools, zoom, focus-search, native text responder actions and clicker navigation. Source-reviewed; interactive keyboard/focus acceptance remains open. |
| 24 | Accessible canvas and controls | Canvas text/state, recording announcements, explicit take selections, named controls and larger transport controls. VoiceOver, focus order and announcement usability need manual acceptance. |
| 25 | Small-screen layout | Independently collapsible sidebars, adjustable split widths, scrolling tool rows and bounded notes. Minimum-size and Split View usability need manual acceptance. |

Additional fixes preserve the presentation queue across pause/resume, rescue
in-memory notes when saving a read-only project elsewhere, and isolate missing
take files while retaining metadata for recovery. Prepared playback clips are
disposable and separate from the portable project. The cache retains three clips
within 512 MiB, or one larger clip alone, avoiding repeated processing on A/B review.

The app remains offline with no third-party runtime dependencies. Rare UI's
MIT-licensed components are adapted to SwiftUI with attribution retained.
Release signing and notarization still require maintainer credentials.
