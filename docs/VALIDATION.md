# Validation

## Automated

```sh
swift test
./scripts/build.sh
codesign --verify --deep --strict 'build/PDF Recorder.app'
lipo -archs 'build/PDF Recorder.app/Contents/MacOS/PDF Recorder'
```

Tests cover timeline seeking, erase/undo, a simulated 30-minute sample clock
with pauses, coordinate round trips, independent retakes and selection,
portable projects, recovery, invalid paths and metadata, rotated/mixed pages,
scans with embedded annotations, and real H.264/AAC MP4 export. Presenter tests
cover legacy project migration and new metadata round trips, search and filters,
export exclusions, next-unrecorded navigation, notes export, playback skip bounds,
countdown cancellation, and audio-only AAC export.

The export test checks duration, 1080p dimensions, frame rate, audio codec,
and agreement between an exported frame and the shared renderer. macOS media
services must be available; a restricted process sandbox may block its encoder.
Do not silently skip the test when the encoder is unavailable.

To retain synthetic test artifacts for inspection:

```sh
PDFRECORDER_TEST_ARTIFACTS="$PWD/build/QA" swift test
```

## Live acceptance checklist

These checks require launching the built app and access to a real microphone.
A simulated clock test does not establish live microphone latency or drift.

- [ ] Open the app at its minimum window size; check light/dark appearances.
- [ ] Check keyboard shortcuts, focus, tool labels, and Reduce Motion.
- [ ] Add titles, notes, bookmarks, and targets; save and reopen to verify retention.
- [ ] Search PDF text and notes, combine filters, and jump to the next unrecorded page.
- [ ] Practice with notes, marks, and timing targets; change pages and end practice.
      Verify no microphone permission prompt, audio file, or new take is created.
- [ ] Cancel both countdown lengths before zero; verify capture never starts.
- [ ] Review at each playback speed and use ten-second skips; verify gestures follow audio.
- [ ] Exclude a recorded page; check combined playback and both export formats skip it.
- [ ] Export notes and an M4A; check page order and confirm notes stay out of media exports.
- [ ] Open a three-page PDF and record each page with voice and gestures.
- [ ] Record two new takes on page two, choose the first, save, quit, and reopen.
- [ ] Verify pointer, pen, highlighter, eraser, undo, pinch zoom, and pan while recording.
- [ ] Pause while speaking/moving, resume, and confirm paused time is absent.
- [ ] Scrub backwards and forwards; compare the scene to normal playback.
- [ ] Export and play the MP4 in QuickTime, verifying sound and page order.
- [ ] Deny microphone permission, then enable it in System Settings and retry.
- [ ] Unplug a USB microphone while recording; confirm partial-take retention.
- [ ] Force-quit during a disposable recording and recover the take on reopening.
- [ ] Test an unwritable project location, insufficient disk space, and cancelled export.
- [ ] Record 30 real minutes with timed spoken/click cues near the beginning and end;
      measure audio/visual alignment, targeting less than 100 ms at both ends.
- [ ] Run the app on an Intel Mac and on the minimum supported macOS 14 version.

## Current local evidence

The implementation has passed core tests and built a signed universal
application on Apple Silicon. Intel is cross-compiled, not yet hardware-tested.
Interactive UI, physical microphone, and real 30-minute checks remain pending.
See CI for verification of the latest commit.
