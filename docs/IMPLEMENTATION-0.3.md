# 0.3 implementation and verification ledger

Scope: implement all 25 improvements requested in the goal attachment, preserving
native macOS 14 support, offline operation, portable projects, and original media.
Live microphone capture and interactive app launch are not authorized for agent QA.
Synthetic media tests, source checks, universal builds and CI are used instead.

| # | Requirement | Evidence to collect |
|---|---|---|
|1|Nondestructive trims|Source-time boundaries, reconstructed start scene, preview/export media tests|
|2|Waveform timeline|Bounded offline analysis; silence and clipping tests; visible seekable timeline|
|3|Independent preview / A-B|Preview ID separate from persisted export selection; comparison controls|
|4|Take names / flags / favorites|Portable metadata and editing controls; round trip tests|
|5|Trash and undo deletion|Atomic metadata operation; restore and preserved media tests|
|6|Explicit microphone check|User-only entry, no saved audio, input status and stop controls|
|7|Volume / loudness / fades|Original preserved; shared audio processing and synthetic output checks|
|8|Recent / pinned projects|Previews, progress, saved workspace and reopen flow|
|9|Persistent preferences|Microphone, countdown, playback speed, notes size, layout round trips|
|10|Storage and recovery|Size/free space, unused takes, readable partials, snapshots and guarded cleanup|
|11|Loops and markers|Source-time metadata, loop playback, labeled seek controls|
|12|Export presets and estimates|Preset media dimensions, bitrate estimates, progress-based ETA|
|13|Range and batch export|Independent selection; atomic batch finalization and cancellation|
|14|Presenter display|Audience-only shared canvas; display selection; private notes and next page|
|15|Teleprompter|Auto-scroll, current-line guide, manual pause, recording pause coordination|
|16|Rehearsal reports|Actual/planned timings, cumulative totals, persisted history, custom target|
|17|Annotation controls|Width/opacity/shapes/text, redo/clear, shared replay and renderer tests|
|18|Sleep protection|Balanced activity lifetime for capture and export, released after stop/failure|
|19|PDF reading/search|Copy/select text, exact matches, outline, printed labels|
|20|Offline OCR|Explicit initiation, cancellable Vision processing, portable fingerprinted cache|
|21|Sharp zoom|Viewport-resolution shared PDF rendering; rotated/annotated geometry tests|
|22|Long-take responsiveness|Checkpoint seek bounds, lazy event loading, background preparation|
|23|Keyboard workflow|Tools, zoom, search, commands, clicker navigation without text-edit conflicts|
|24|Accessibility|Canvas text, announcements, focus/labels/selection states, larger controls|
|25|Small-screen layout|Independent collapsible sidebars and expandable notes|

Also fix the audited presentation pause queue, failed-save rescue path, damaged-take
isolation, and focused text undo behavior. This ledger is a scope checklist, not a
claim of completed verification; final evidence will be recorded after integration.
