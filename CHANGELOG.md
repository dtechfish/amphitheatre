## 0.1.0

Ground-up rewrite of the export pipeline. Exports of arbitrarily large videos
are now safe: video data is never loaded into memory and all processing runs
off the UI thread.

**Highlights**

* New `AmphitheatreExporter` API: path-based exports with real progress
  (`Stream<double>`), cancellation, and typed errors
  (`AmphitheatreExportException`).
* Optional compression: `AmphitheatreExportQuality` (passthrough / 2160p /
  1080p / 720p) — set `AmphitheatreEditorOptions.exportQuality`.
* Android now uses `androidx.media3` Transformer (passthrough transmux for
  pure trims from the key frame at or before the start, H.264/AAC transcode for compression,
  streamable fast-start MP4 output).
* iOS uses the modern `AVAssetExportSession` API on iOS 18+
  (`export(to:as:)` + `states(updateInterval:)`) with a compatible fallback
  for iOS 13–17, and enables `shouldOptimizeForNetworkUse` (fast-start).
* The editor's export screen shows real progress with cancel, and failures
  surface a recovery UI (retry / back to editor) instead of hanging forever.
* The trim slider is now a filmstrip: frame thumbnails, a scrim outside the
  selection, refined handles, and start/selected/end timestamps.
* The editor undo history is bounded and gesture-coalesced;
  `AmphitheatreEditorController` gains `undo`/`canUndo`/`commitPending`.
* The player shows a proper error state when a video fails to load.
* Ships an Apple privacy manifest (`PrivacyInfo.xcprivacy`); Android
  `compileSdk` 36.
* The input video is never modified or deleted by the plugin.

**Breaking changes**

* `AmphitheatreController.getVideo()` and `AmphitheatreVideo` (bytes-based)
  were removed. Use `AmphitheatreController.resolveVideoFilePath()`.
* `AmphitheatreExporterProgressBuilder` now receives an
  `AmphitheatreExportUiState` instead of a `progress` double.
* `AmphitheatrePlatform.cropVideo` was replaced by
  `startExport`/`cancelExport`/`getThumbnails` and a progress event stream.
* `AmphitheatreEditorController.crop`'s `irreversible` parameter was replaced
  by `commit`/`markInitial`.
* Editor auto-accept of short videos is now opt-in via
  `AmphitheatreEditorOptions.autoAcceptShortVideos` (it was documented but
  never implemented before).
* Android `minSdk` raised from 21 to 23 — required by androidx.media3 1.10
  (the AndroidX baseline policy moved to 23 in mid-2025). Media3 itself is
  self-contained: no Google Play Services dependency and no bundled native
  libraries.
* Requires Flutter 3.27+.

## 0.0.3

* Allow customizing the playback controls in the editor.

## 0.0.2

* [Video Limit #1](https://github.com/apollosoftwarexyz/amphitheatre/issues/1) Add basic options to
  `Amphitheatre.consume` and `AmphitheatreEditor.consume` to facilitate setting - amongst other options - the video 
  length for the editor.
* [Autoplay not working #2](https://github.com/apollosoftwarexyz/amphitheatre/issues/2): Trigger autoplay logic after
  initialization.
* Add `useRootNavigator` convenience property to launch methods (useful for opening a full screen editor or player in
  nested navigation contexts).
* Documentation changes
* Bump dependencies

## 0.0.1+1

* Documentation changes

## 0.0.1

* Initial release
