# Project format v3

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
  trash.json             # recoverable deleted-take metadata; media stays in takes/
  unavailable-takes.json # metadata retained for missing files
  snapshots/<UUID>.json  # manifest checkpoints sharing immutable media
  rehearsals.json        # timing-only practice history
  reading/ocr.json       # optional locally recognized text and geometry
```

`manifest.json` contains `version`, a project UUID, title, source path, and an
ordered `pages` array. Every page holds `takes` and an optional `selectedTakeID`.
Page indexes are zero-based. A take has a UUID, ISO-8601 creation date, duration
in seconds, initial viewport, relative audio/events paths, and a recovery flag.
The selected take is the one used for presentation playback and export. The app
may audition a different take without changing that saved selection.

Version 2 adds optional page fields:

| Field | Type | Default when absent |
| --- | --- | --- |
| `title` | String | Page number |
| `notes` | String | Empty |
| `bookmarked` | Boolean | False |
| `targetSeconds` | Number, 0–86400 | No timing target |
| `includedInExport` | Boolean | True |

Notes and page settings save after a short typing debounce, and flush before
switching projects, recording, practicing, exporting, or quitting. Notes are
plain text in the package; they are never passed to the video renderer.

The app accepts v1, v2 and v3. Older manifests upgrade in memory on load,
preserving all takes and selected IDs. Reading alone does not rewrite them;
subsequent saves write v3. Older apps cannot open v3 projects. Unknown future
versions are rejected.

Version 3 adds these optional take fields, defaulting to the original unedited
behavior when absent:

| Field | Meaning |
| --- | --- |
| `trimStart`, `trimEnd` | Kept range in original source seconds; source files unchanged |
| `name`, `favorite`, `reviewStatus` | Review metadata; status is unreviewed/ready/needsCorrection |
| `reviewMarkers` | UUID, source timestamp, and label for each review note |
| `loopRange` | Source start/end for optional A–B review, constrained to the trim |
| `gainDB` | Nondestructive gain adjustment applied during preview/export |

The manifest also accepts `matchLoudness`, an optional Boolean. Trims reconstruct
all prior scene events before showing the first kept frame; recorded gestures
and audio retain one source-time coordinate system. Review markers outside a
later trim remain in metadata. Loops outside the trim are cleared when editing.

Microphone/countdown/playback/notes/layout preferences and recent/pinned projects
are local JSON files under Application Support/PDF Recorder, separate from the
portable project. Each recent entry keeps its path, page, viewport, progress,
and optional thumbnail. Moving a project updates its library entry when opened.
Disposable prepared audio is stored in a separate `Playback Cache` directory
under the same Application Support root. It is not copied into project packages.
At most three clips are retained within 512 MiB, allowing a single oversized clip
alone. Clearing this cache does not alter source media or project metadata.

The original PDF is copied byte-for-byte and never rewritten. Passwords are
kept in memory only; encrypted source PDFs remain encrypted in the package.
**Recordings are not encrypted**, including recordings made from an encrypted
PDF. Opening that project again requests the PDF password.

## Timeline

`events.json` is an ordered array of `{time, action}` records. Actions use Swift
Codable's tagged enum representation. Actions are `pointer`, `viewport`,
`beginStroke`, `extendStroke`, `removeStroke`, and `restoreStroke`. Equal
timestamps preserve event order.

In v3, `restoreStroke` can include an optional nonnegative `index` to restore a
mark at its original layer position. Older events without `index` retain their
original append behavior. This keeps erase/undo and Clear Marks deterministic
even when marks overlap.

Page coordinates are normalized to the rotation-corrected displayed page,
with `(0,0)` at bottom-left and `(1,1)` at top-right. Stroke width is a fraction
of displayed page width. Viewport offsets are fractions of the 16:9 canvas,
with a zoom from 1 through 8. Canvas resizing does not change recorded data. Version 3 strokes may include
`opacity`, `shape` (line/arrow/rectangle/ellipse/text), and `text`. Shapes and labels
use the same timed stroke events. Undo, redo, and Clear Marks append inverse
stroke actions; they do not rewrite earlier events. Search and text-selection
highlights are editor-only and never enter the event log.

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
unsupported versions and invalid metadata are rejected. Missing take files can
be isolated after an explicit user choice, preserving their metadata and allowing
healthy pages to open. Restored files can be retried through Storage & Recovery.
Save As stages an editable copy and writes in-memory notes there even when the
original location is read-only.

If a partial take cannot be recovered, **Keep Aside & Start New Take** preserves
its metadata as `unfinished-<UUID>.json` and leaves all its files in the package.
This avoids blocking the rest of the project. Such files are retained for manual
inspection and are not included in playback or export. Storage & Recovery can
retry these recordings after any active unfinished take has been handled.

Deleting a take journals its metadata to `trash.json` before removing it from the
manifest. Restoration commits the manifest before removing the trash entry.
An interrupted operation may leave a duplicate, never lose the only metadata.
Snapshots retain complete manifests and refer to existing immutable take files.
Restoring a snapshot creates a checkpoint of the current state and moves newer
takes into Trash. Permanent deletion refuses files still used by the current
manifest or a snapshot. Snapshot removal and permanent deletion are explicit.

OCR caches include normalized character geometry and a SHA-256 source fingerprint.
Each recognized page saves atomically; cancellation keeps completed OCR work.
Recognition uses Apple Vision locally and does not write to the source PDF.
Rehearsal history is separately versioned and stores timing, targets and visits,
without any microphone or gesture capture.

## Export

Only selected takes on pages whose `includedInExport` is not false are included,
in original PDF order. Excluding a page retains its takes and selection. Combined
playback follows the same choices; individual page playback is still available.
Each video take is rounded
up to the next 1/30-second frame boundary, adding at most 33 ms of trailing
silence. Standard output is 1920×1080, 30 fps, H.264/AAC in MP4. Small upload uses
1280×720 at approximately 2 Mbps; Standard uses 6 Mbps and High quality 12 Mbps.
All use 30 fps; bitrate-derived file sizes and progress-derived time are estimates. Export writes to a
temporary destination and only replaces an existing file after completion.

Audio-only export joins the same trimmed takes into AAC in an M4A container, using their
audio durations without video-frame rounding. It also stages output and only
finalizes after success. Playback speed does not change either export format.
Notes can be explicitly exported as a separate UTF-8 Markdown document with
page titles and timing targets; notes never appear in video or audio exports.
Practice creates no audio, event journal, or take metadata. Volume changes and
optional speech-level matching are applied to a temporary PCM copy with short
edge fades before preview/export. Source PCM is preserved. Export ranges and
chapter selections do not mutate saved page inclusion flags. Batch export stages
all page files inside a new temporary directory, then renames it after success.

The shared renderer draws PDF vectors at the destination resolution, including
crop offsets, rotation and imported annotations. A bounded background cache stores
the visible viewport for editor/audience redraws. Scanned images retain the detail
available in their source. Export processes events incrementally; interactive
seeking uses bounded scene checkpoints.
