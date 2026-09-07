# Validation

## Automated

```sh
swift test
./scripts/build.sh
codesign --verify --deep --strict 'build/PDF Recorder.app'
lipo -archs 'build/PDF Recorder.app/Contents/MacOS/PDF Recorder'
```

The automated suite uses generated PDFs and audio. It never launches the
application, starts a microphone or plays through an audio output device.
Controller tests use isolated storage, disabled device discovery and fake
playback. Real AVFoundation encoding and Vision OCR run on fixtures.

Coverage includes:

- Timeline reconstruction, checkpointed long seeks, chunked event logs,
  annotation replay/layer order, rotated/mixed geometry, vector detail at deep
  zoom, exact text matches, outlines, page labels and synthetic scanned-page OCR.
- A simulated 30-minute sample clock with pauses; source-time trims, loops,
  markers, A/B preview independent of export selection, and presentation
  pause/resume with the remaining page queue intact.
- Portable formats v1/v2/v3/v4, preferences and workspace round trips, take Trash,
  snapshot protection, missing-media isolation/retry, partial recovery and
  Save As rescue from a read-only original project.
- Multiple source PDFs: ordered batch import, rollback before the manifest commit,
  stable existing page/take indexes, mixed source geometry, document-local range
  and chapter selection, per-document page/viewport restoration, source-preserving
  portable saves, and snapshot restoration that retains later appended PDFs.
- Search failure clears its busy indicator without publishing a partial index.
  Save As waits for cancelled OCR/cache writers and review/search readers before
  copying or deleting recovery storage; failed and cancelled saves preserve work.
- Waveform silence/clipping, gain, volume matching, fades and source preservation;
  playback cache reuse/invalidation/eviction, interrupted preparation, cleanup
  during preparation and recovery of scrubbing after cancelled/failed preparation.
- Real H.264/AAC MP4 and AAC M4A output, dimensions, frame rate, duration,
  agreement with the shared renderer, and the scene at a trimmed start.
- Page-range parsing, ordered batch export, cancellation, failure atomicity and
  preservation of prior output. Rehearsal timing/history, teleprompter clocks,
  trim-aware pacing, synthetic input feedback and balanced idle-sleep protection.

macOS media services must be available; a restricted process sandbox may block
the encoder. Do not silently skip the export tests when this happens.

The short AAC trim regression checks the exact decoded PCM sample count.
On macOS 14, an M4A duration read can differ by the 2,112 encoder-priming samples
while the decoded audio retains the full trim. The test accepts either duration
representation within one sample, rather than loosening sample-count accuracy.
MP4 assembly uses the known PCM presentation length. See Apple's
[AAC priming explanation](https://developer.apple.com/documentation/quicktime-file-format/background_aac_encoding).

To retain synthetic test artifacts for inspection:

```sh
PDFRECORDER_TEST_ARTIFACTS="$PWD/build/QA" swift test
```

## Interactive acceptance checklist

These checks are tracked separately from automated tests. Interactive UI review
requires a deliberate app launch; audio input and audible playback are separate
checks. No physical microphone or long-session result is implied by a passing
synthetic clock test.

- [ ] Open at the minimum size and in Split View; independently collapse sidebars,
      expand notes, and check the dark interface with Reduce Motion.
- [ ] Multi-select three PDFs or drop them together. Switch document tabs, navigate
      each source, and verify titles, thumbnails, local page numbers, and last
      viewports. Add another PDF without disturbing existing notes or takes.
- [ ] Mix portrait, landscape, rotated, and mixed-size source PDFs. Save and reopen
      the project after moving the original files. Verify every source remains
      readable, with unchanged geometry and independently selected takes.
- [ ] Search and use outlines in each document. Check current-PDF OCR caches,
      document keyboard shortcuts, and locked document navigation during a take.
- [ ] Export all documents, one document, a current-document range, and a chapter;
      inspect cross-document page order, page geometry, and unique batch filenames.
- [ ] Complete the workflow using the keyboard. Check command search, text-editing
      Undo/Redo, canvas focus, page-number entry and presentation-clicker keys.
- [ ] Use VoiceOver on PDF text, take cards, waveform controls and recording-state
      announcements; check focus order and larger controls.
- [ ] Pin projects, set preferences, move a saved project, quit and reopen;
      verify previews, page/viewport restoration and encrypted-PDF passwords.
- [ ] Select/copy native and OCR text, find exact matches, navigate PDF outlines
      and printed labels, and cancel OCR between pages.
- [ ] Practice with custom targets and a teleprompter; pause, scroll manually,
      revisit pages and check the saved actual/planned report. Verify practice
      creates no audio, event journal, take or microphone permission prompt.
- [ ] Choose an audience screen, enter fullscreen, use a clicker, disconnect it
      and reopen the audience view. Verify private notes/controls never appear.
- [ ] Explicitly check a microphone; confirm the resolved device name, silence,
      quiet/clipping feedback, and verify no audio file is saved.
- [ ] Cancel countdown before zero; then record three pages with voice/gestures.
      Redo page two, audition alternatives, select an earlier take, save and reopen.
- [ ] Draw overlapping marks, shapes and labels at several zooms; erase a lower
      mark, undo/redo, clear/undo, and compare preview, scrubbed and exported scenes.
- [ ] Pause while speaking/moving; resume and verify paused time is absent and
      prompter pause state agrees. Test permission denial and USB disconnection.
- [ ] Trim a take, compare A/B at matching offsets, add markers, enable a loop,
      vary playback speed, and pause/resume presentation playback across pages.
- [ ] Cancel long-take playback preparation and immediately scrub/replay; change
      gain/matching, repeat A/B comparisons and clear the playback cache.
- [ ] Delete/undo a take, restore Trash/snapshots, isolate and retry missing media,
      and recover a readable partial take.
- [ ] Export ranges, chapters and separate pages in every preset; cancel mid-batch
      and confirm no published partial folder or replacement of earlier output.
- [ ] Play MP4/M4A in QuickTime; check page order, selected takes, gesture alignment,
      fades and volume across page boundaries.
- [ ] Exercise force-quit recovery, unwritable locations and insufficient disk;
      confirm completed takes remain and Save As rescues unsaved metadata.
- [ ] Record 30 real minutes with timed spoken/click cues near beginning/end;
      measure audio/visual alignment, targeting less than 100 ms at both ends.
- [ ] Run on Intel hardware and the minimum supported macOS 14 version.

## Evidence ledger

The 0.4.0 development preview passes **95 automated tests** and a universal
Release build locally on Apple Silicon with Xcode 26.6. This includes nine
dedicated multi-PDF core tests, six headless multi-PDF workflow tests, and four
Save As/OCR lifecycle tests.
Both `arm64` and `x86_64` slices are present; strict deep signature verification
passes. The ad-hoc signed app occupies approximately **14 MB** on disk and its
ZIP **4 MB**, excluding projects. The macOS CI workflow runs the full suite,
universal build and signature checks; consult the run for the exact commit
being reviewed.

The 0.4 app launches locally. Interactive review confirmed the dark welcome
screen, importing three PDFs together, document tabs, and switching between
portrait and landscape pages. Other interactive checklist items remain pending.
The first launch exposed a hardened-runtime rejection of the ad-hoc signed
embedded core framework; the app now links that code statically, and CI checks
that no dynamic core dependency returns. Microphone recording has not been
authorized or performed during implementation.

Intel is cross-compiled, not hardware-tested. VoiceOver, physical microphone,
multi-display and real 30-minute checks remain pending. See the
[implementation ledger](IMPLEMENTATION-0.3.md) for each requirement.

For local visual review, the demonstration documents in `build/Demo Documents`
contain six deliberately generated pages: portrait biology notes, a landscape
statistics exercise with invented data, and a speaking worksheet that changes
page size. They contain no microphone recordings or private material. The PDFs
were authored with Swift/CoreGraphics, rendered through Poppler, and visually
checked for clipping, spacing, readable labels, and page geometry. These local
demo artifacts are not bundled into the app or committed as source assets.
