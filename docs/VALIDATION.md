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
- Portable formats v1/v2/v3, preferences and workspace round trips, take Trash,
  snapshot protection, missing-media isolation/retry, partial recovery and
  Save As rescue from a read-only original project.
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

To retain synthetic test artifacts for inspection:

```sh
PDFRECORDER_TEST_ARTIFACTS="$PWD/build/QA" swift test
```

## Interactive acceptance checklist

These checks remain open. Application launch and microphone testing were declined
by the user, so agent verification uses the automated boundaries above. A passing
synthetic clock test does not establish real microphone latency or drift.

- [ ] Open at the minimum size and in Split View; independently collapse sidebars,
      expand notes, and check light/dark mode and Reduce Motion.
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

## Current evidence

The 0.3.0 implementation passed **76 automated tests** and a universal Release
build locally on Apple Silicon with Xcode 26.6. Both `arm64` and `x86_64` slices
are present; strict deep signature verification passes. The ad-hoc signed app
occupies approximately **12 MB** on disk and its ZIP **4 MB**, excluding projects.
The macOS CI workflow runs the same tests, universal build and signature checks;
consult the run for the commit being reviewed.

Intel is cross-compiled, not hardware-tested. Interactive UI, VoiceOver, physical
microphone, multi-display and real 30-minute checks remain pending. See the
[implementation ledger](IMPLEMENTATION-0.3.md) for each requirement.
