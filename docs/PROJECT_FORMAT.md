# Project format v1

A `.pdfrecorder` project is a Finder package directory. It is self-contained;
copying or moving the package also moves the PDF and recordings.

```text
Lecture.pdfrecorder/
  manifest.json
  source.pdf
  takes/<take UUID>/
    audio.caf
    events.json
    events.ndjson       # temporary crash-recovery journal; removed on success
  active-take.json       # exists only while a take is unfinished
```

`manifest.json` contains `version`, a project UUID, title, source path, and an
ordered `pages` array. Every page holds `takes` and an optional `selectedTakeID`.
Page indexes are zero-based. A take has a UUID, ISO-8601 creation date, duration
in seconds, initial viewport, relative audio/events paths, and a recovery flag.
The selected take is the one used for page playback and export.

The original PDF is copied byte-for-byte and never rewritten. Passwords are
kept in memory only; encrypted source PDFs remain encrypted in the package.
**Recordings are not encrypted**, including recordings made from an encrypted
PDF. Opening that project again requests the PDF password.

## Timeline

`events.json` is an ordered array of `{time, action}` records. Actions use Swift
Codable's tagged enum representation. Actions are `pointer`, `viewport`,
`beginStroke`, `extendStroke`, `removeStroke`, and `restoreStroke`. Equal
timestamps preserve event order.

Page coordinates are normalized to the rotation-corrected displayed page,
with `(0,0)` at bottom-left and `(1,1)` at top-right. Stroke width is a fraction
of displayed page width. Viewport offsets are fractions of the 16:9 canvas,
with a zoom from 1 through 8. Canvas resizing does not change recorded data.

Microphone audio is written as mono 48 kHz, 16-bit PCM CAF. CAF supports readable
partial recordings better than a movie container that needs finalization.
Audio sample counts drive event timestamps. Paused buffers are neither written
nor counted. One raw hour of audio is approximately 346 MB; visual events add
to that. Final MP4 audio is AAC.

## Saving and recovery

The app writes events before atomically replacing the manifest, so a failed
take finalization cannot replace a previously selected take. Recording journals
append only new events every two seconds and sync them before atomically
updating active-take metadata. Recovery discards a truncated final journal
line, uses the audio file's actual readable duration, and adds a recovered take.
Up to two seconds of gestures may be absent after a hard crash. Recoverable
audio depends on the last buffers successfully written by the operating system.

Unsaved projects live in:

```text
~/Library/Application Support/PDF Recorder/Recovery/
```

Save Project copies the package to a chosen location. Completed projects then
autosave there. Project paths are relative; symbolic links, escaping paths,
unsupported versions, invalid metadata, and missing recording files are rejected.

If a partial take cannot be recovered, **Keep Aside & Start New Take** preserves
its metadata as `unfinished-<UUID>.json` and leaves all its files in the package.
This avoids blocking the rest of the project. Such files are retained for manual
inspection and are not included in playback or export.

## Export

Only selected takes are included, in original PDF order. Each take is rounded
up to the next 1/30-second frame boundary, adding at most 33 ms of trailing
silence. The output is 1920×1080, 30 fps, H.264/AAC in MP4. Export writes to a
temporary destination and only replaces an existing file after completion.

The renderer caches a rotation-corrected page bitmap with a maximum dimension
of 3840 pixels. This bounds memory and preserves PDF annotations, but very deep
zoom can soften small text. Preview and export share this behavior.
