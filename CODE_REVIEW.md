# Amphitheatre v0.0.3 — Full Code Review

Reviewed: 2026-07-25. Scope: every source file in the package (Dart, Kotlin, Swift), docs, build config, and tests. Context: used in a Flutter app to trim/compress video before CDN upload; app crashes and/or never finishes exporting large files.

**Verdict: the large-file crash is not one bug — it is a pipeline of five compounding defects, any one of which is fatal for a big video. The export path needs a ground-up rewrite; the player/editor UI is mostly salvageable.**

---

## 1. Root cause of the large-file crash (the chain)

### 1.1 Entire video loaded into RAM — `lib/src/amphitheatre_controller.dart:185-229`
`AmphitheatreController.getVideo()` does `await XFile(uri.path).readAsBytes()` — the **whole video file into a single `Uint8List`**. `produceOutputVideo()` (`lib/src/editor/amphitheatre_editor.dart:316`) then wraps it in `XFile.fromData()` and `saveTo()`s a byte-for-byte copy into the plugin cache dir.

- A 5–10 minute phone recording is easily 1–6 GB. iOS jetsam kills apps far below that (roughly 1.4–2 GB on new devices, a few hundred MB on older ones). **Instant crash on iOS.**
- The absurdity: in the primary flow the video is *already a file on disk*. The read exists only to copy it into the cache directory. A path handoff (or stream copy) would use O(1) memory.
- `AmphitheatreVideo.data` bakes "bytes in memory" into the public API, so this can't be fixed without an API change.

### 1.2 All file I/O on the UI isolate — same function
The gigabyte read and write both run on the main Dart isolate. UI freezes completely for the duration; on Android this alone can trigger an ANR kill.

### 1.3 Android: entire native operation on the main thread — `AmphitheatrePlugin.kt:34-188`
`onMethodCall` performs the full `MediaExtractor`/`MediaMuxer` remux **synchronously on the platform main thread**. For a large file this takes tens of seconds to minutes → **ANR → system kills the app**. This exactly matches "the phone can never finish exporting."

### 1.4 Android: MP4 faststart parser loads the whole file into JVM heap — `MP4.kt:388-454`
After remuxing, the plugin runs `MP4(outputFile.inputStream())`. The `init` block eagerly parses **every box into a `ByteArray` in memory — including `mdat`, which is ~99% of the file size**. Android's Java heap cap is typically 256–512 MB, so **any output over a few hundred MB throws `OutOfMemoryError`**, which is uncaught (see 1.5) → hard crash. This kills Android exports even when the Dart side survived (Dart `Uint8List`s live on the native heap; this lives on the constrained JVM heap).

Additional hard limits in the same file:
- Box sizes are read as signed 32-bit `Int` (`Box.readFrom`, `MP4.kt:156-189`). A box between 2 GB and 4 GB wraps negative → `NegativeArraySizeException`. The 64-bit `largesize` path explicitly throws `UnsupportedOperationException` above `Int.MAX_VALUE`. **Videos with >2 GB mdat can never work.**
- `InputStream.next(n)` (`MP4.kt:45-49`) ignores the return value of `read()` — partial reads silently corrupt the parse.
- `InputStream.available()` used as an EOF signal (`MP4.kt:421`) — not what `available()` guarantees.
- `makeStreamable` does `boxes.last() as MovieBox` (`MP4.kt:428`) — assumes `moov` is the final box; `ClassCastException` otherwise.

### 1.5 Native errors crash the app or hang it forever
- **Android:** the only `catch` in `onMethodCall` handles `IllegalMethodCallArguments` (`AmphitheatrePlugin.kt:185`). Everything else — `IOException` from `setDataSource`/`MediaMuxer`, `NumberFormatException` from the rotation parse (line 133), OOM and cast errors from `MP4` — propagates on the main thread → **process crash**.
- **Android silent hang:** inside the track loop, `format.getString(KEY_MIME) ?: return` (line 83) is a **non-local return from `onMethodCall`** (inline `forEach`), so a track with no MIME type exits without ever calling `result` → the Dart future never completes.
- **Dart:** `produceOutputVideo()` has **no try/catch**. Any `PlatformException` is swallowed by `unawaited()`, `_exporting` stays `true`, and the export screen is wrapped in `PopScope(canPop: false)` (`amphitheatre_editor.dart:410`) with no cancel button. **The user is permanently stuck on "Exporting video…" and must force-kill the app.**

### 1.6 Progress is fake
`build()` calls `widget.buildExporterProgress(progress: 0)` — hardcoded zero (`amphitheatre_editor.dart:351`). Neither platform reports progress (no EventChannel; `AVAssetExportSession.progress`/`states()` unused; the Android remux loop reports nothing). So even a *successful* long export looks like a hang at 0%.

**Net effect for a large file:** UI freezes during the RAM-doubling read/copy → if iOS, jetsam kill; if Android, survive to native → main-thread remux risks ANR → MP4 faststart pass OOMs the JVM heap → uncaught → crash. Every branch ends in "crashed" or "stuck at 0% forever."

---

## 2. There is no compression — a business-logic gap

You are using this package to "compress, trim, and upload." **It only trims.**

- **Android** (`AmphitheatrePlugin.kt`): pure remux (stream copy). Output bitrate = input bitrate. Zero size reduction beyond the removed duration.
- **iOS** (`AmphitheatrePlugin.swift:136`): `AVAssetExportPresetHighestQuality` — re-encodes at *highest* quality. Slow (minutes for long 4K video) and can even produce a *larger* file.

If CDN-friendly file sizes are a goal, transcoding with a target resolution/bitrate must be added on both platforms; it does not exist today.

---

## 3. Other defects by area

### 3.1 Android plugin (`AmphitheatrePlugin.kt`)
| # | Issue | Location |
|---|-------|----------|
| A1 | `bufferSize = min(KEY_MAX_INPUT_SIZE, -1)` is always `-1` — the track-derived size is never used (author almost certainly meant `max`). Falls back to 8 MB; a sample larger than the buffer throws → export fails. | 74, 106-112 |
| A2 | Loop condition `extractor.sampleTime <= end * 1000` ends the entire remux when *any* track's next sample passes `end` — the other track can be truncated early (A/V tail desync). | 142 |
| A3 | `SEEK_TO_CLOSEST_SYNC` can snap up to a full GOP (seconds) *before* the requested start; with no re-encode the trim start is imprecise. | 137 |
| A4 | `muxer.release()` / `muxer` not in `finally`; leaks on failure paths. Odd 3-attempt retry loop for `metadataRetriever.release()`. | 120-130, 163-171 |
| A5 | Input file deleted by the native layer (`inputFile.delete()`) — deletion policy baked into the wrong layer; on the no-crop path the Dart side returns the *undeleted* temp copy → inconsistent contract, cache-dir bloat (nothing ever cleans the plugin cache dir). | 180 |
| A6 | `onDetachedFromEngine` calls `onDetachedFromActivity` (clears the handler) but never nulls `activity` — stale `Activity` reference retained (leak) when the activity detaches without engine detach. | 220-223 |

### 3.2 iOS plugin (`AmphitheatrePlugin.swift`)
| # | Issue | Location |
|---|-------|----------|
| I1 | `result(...)` is called from inside `Task.init` on a background executor. Flutter requires channel replies on the platform (main) thread → undefined behavior, intermittent crashes. | 63-84 |
| I2 | iOS 18+ path uses the new `export(to:as:)` then switches on the **deprecated** `status` property; if `status` isn't updated by the new API the code throws "illegal state" after a *successful* export. | 144-162 |
| I3 | All errors collapsed to `"The operation failed."` — the underlying `AVFoundation` error never reaches Dart; undiagnosable in production. | 66-71, 157 |
| I4 | No progress, no cancellation (`progress`/`states(updateInterval:)`/`cancelExport` unused). | — |
| I5 | `AVAssetExportPresetHighestQuality` (see §2) — wrong preset for a compression use case; `shouldOptimizeForNetworkUse` (free faststart!) never set, so iOS output isn't streamable even though Android goes to great lengths for this. | 136-150 |
| I6 | Dead shadowed declarations in `parseCropVideoArgs` (`let path: String` etc.). | 95-107 |

### 3.3 Dart editor (`amphitheatre_editor.dart`, `_controller.dart`)
| # | Issue | Location |
|---|-------|----------|
| D1 | **Controller disposed mid-export.** `setState(() => _exporting = true)` unmounts the inner `Amphitheatre.consume`, whose `dispose()` disposes the `AmphitheatreController`/`VideoPlayerController` while `produceOutputVideo()` is still reading `duration`/`dataSource` from it. Works only because reading a disposed `ValueNotifier` isn't checked in release mode; asserts in debug. | 316-346, 350 |
| D2 | `Navigator.of(context).pop(...)` after multiple awaits with no `mounted` check. | 345 |
| D3 | `shouldAutoAccept` is **never called** — the documented min-length auto-accept behavior doesn't exist. Its doc comment also contradicts itself about `strict`. | 22-49 |
| D4 | `AmphitheatreEditorController._history` grows unboundedly — one entry per drag-update event (hundreds per gesture); no undo API ever exposed; only `hasModification` reads it. | editor_controller 56-101 |
| D5 | `_ensurePlaybackWithinCropRegion` runs on **every** controller tick and issues `seekTo` repeatedly at region boundaries — seek storms; `seekTo` also auto-`play()`s when the video is completed. | 574-602; controller 153-159 |
| D6 | `AmphitheatreEditorOptions.==`/`hashCode` omit `strict`; `AmphitheatreEditorStyle.==`/`hashCode` omit the four icon fields. | 71-79, 140-160 |
| D7 | Temp file named from `video.name` — collisions between successive exports silently overwrite. | 329 |
| D8 | Slider position math uses different padding formulas in `_handleNewCropPosition` vs `_valueToPosition` — handle tracking drifts from the finger. | 724-845 vs 1001-1014 |
| D9 | `_loadImages` catches and ignores all errors, and can set state with stale icons when style changes race. | 656-670 |

### 3.4 Dart player/core
- `_onControllerUpdate() => setState(() {})` rebuilds the entire player UI on every position tick (`amphitheatre.dart:291`; same pattern in the editor slider) — constant rebuild churn.
- `AmphitheatreController.initialize()` ignores errors from `controller.initialize()` — a bad/corrupt file yields a silent black screen (`amphitheatre_controller.dart:131`).
- `getVideo()` supports only file/asset sources; network is `UnimplementedError`.
- Web/desktop: `cropVideo`/`getTemporaryDirectory` have no implementations → `MissingPluginException` at runtime; nothing guards `kIsWeb`.
- l10n: `exportingVideo(progress)` interpolates the raw double — renders "Exporting video (0.0)..." rather than a percentage.

### 3.5 Package health
- **Zero Dart tests** (no `test/` directory in the package). Kotlin tests cover only byte-conversion helpers and argument parsing — none of the remux, box parsing, or `makeStreamable` logic. No CI config in the repo.
- v0.0.3, ~7 commits, single maintainer — pre-alpha maturity.
- README describes a "video player and editor" — the compress/upload expectations are outside its actual scope.

---

## 4. Rewrite recommendations

### Architecture
1. **Paths, never bytes.** The export API should accept and return file paths. Kill `AmphitheatreVideo.data` / `getVideo()`. If a cache copy is truly needed, stream-copy off the UI isolate — but prefer passing the original path and **never deleting the caller's input** (return the output path; cleanup is the caller's job).
2. **Typed, async platform API with progress + cancel.** Pigeon (or method channel + EventChannel) exposing:
   `startExport(input, start, end, quality) → exportId`, `Stream<double> progress`, `cancel(exportId)`, completion with output path or a typed error (code + native message). All native replies posted on the platform thread.
3. **Android: use `androidx.media3.transformer`.** It handles trimming, optional transcoding (target resolution/bitrate — your actual compression requirement), progress callbacks, and correct threading, and is maintained by Google. It removes the entire hand-rolled `MediaExtractor`/`MediaMuxer` loop and its bugs (A1–A4).
4. **iOS: pick preset by target quality** (e.g. `AVAssetExportPreset1920x1080` / `AVAssetWriter` for bitrate control), set `shouldOptimizeForNetworkUse = true` (faststart for free), use `states(updateInterval:)` (18+) / `progress` polling for progress, `cancelExport()` for cancel, and hop to the main actor before calling `result`. Surface `exportSession.error` details to Dart.
5. **Delete `MP4.kt` entirely.** iOS gets faststart from the flag above. On Android, if faststart matters for your CDN, implement the standard streaming qt-faststart pass (read only headers, shift `stco`/`co64`, stream-copy `mdat`; ~200 lines, O(1) memory) — or skip it and let the CDN transcode handle delivery.
6. **Export lifecycle in Dart:** keep the video controller alive until export completes; `try/catch/finally` around the whole flow with `_exporting` reset; error UI with retry/cancel; `mounted` checks after awaits; allow backing out; consider a wakelock during export.
7. **Buy vs. build:** if you only need trim + compress for upload, evaluate maintained packages (e.g. media3-transformer-based plugins, `video_compress`-class packages) and keep only Amphitheatre's UI layer, which is the salvageable part (player, slider, crop handles — modulo D5/D8 fixes and per-tick rebuild reduction).

### Testing for the rewrite
- Golden MP4 fixtures (H.264/HEVC, rotated, multi-track, >4 GB sparse) exercised in Android instrumentation + iOS XCTest.
- A "large file" integration test that asserts peak memory stays flat during export.
- Dart unit tests for the editor controller (crop clamping, min/max length) and widget tests for the export failure path (error → user can leave the screen).

---

## 5. Addendum (2026-07-25): responses to developer notes

Responses to Samuel Jakob's notes on this review, for the record:

**"The current implementation doesn't stream large files, which is likely the issue."**
Agreed — that is the root cause, and it is what the v0.1.0 rewrite fixes (paths end-to-end, streaming native pipelines, no bytes in Dart memory).

**"That would require like 2+ GiB."**
The old pipeline fails well below 2 GiB, on three independent paths:

1. *Android JVM heap (the practical killer):* after the remux, `MP4.kt` eagerly parsed the **entire output file — including `mdat` — into Java byte arrays**. The Android Java heap cap is 256–512 MB on most devices (`largeHeap` at best ~1 GB), so **`OutOfMemoryError` fires from roughly a few hundred MB of video**, not 2 GiB. This heap is separate from (and much smaller than) the native heap that Dart's `Uint8List`s use, which is why the Dart-side read could survive and the Kotlin side still crashed.
2. *Android ANR:* the remux ran synchronously on the main thread. ANR is time-based (~5 s of blocked input), not size-based — a remux of even a few hundred MB on slow flash, plus one screen tap, kills the app regardless of heap.
3. *iOS jetsam:* memory limits are device-dependent and well under 2 GiB on older hardware; the Dart read + temp-file copy also transiently holds more than the file size.

**"iOS compresses the file before it even gives it to the app."**
True for `UIImagePickerController`-based pickers (which `image_picker` uses; it may transcode on the way in) — but not for camera-roll originals obtained via `PHPickerViewController` with original versions, the camera plugin, or files shared into the app. Two implications: (a) Android receives untranscoded originals, which is consistent with the crash chain above being Android-heavy; (b) the rewrite defaults to `passthrough` quality, so already-compressed iOS inputs are not compressed a second time.

**"MOV atoms already have a 32-bit limit... no MOV atom is going to be that big."**
Partially disagree as a spec matter: ISO BMFF/QuickTime support atoms larger than 4 GiB via `size == 1` + 64-bit `largesize`, and the `mdat` atom of a long recording routinely **is** that big — that's exactly why `co64` (64-bit chunk offsets, which `MP4.kt` itself implemented) exists. So the 32-bit size paths were real limits, though secondary ones. The primary defect was independent of atom size: `mdat` of *any* size was loaded into the JVM heap (point 1 above). Either way it is moot now — `MP4.kt` is deleted in the rewrite; fast-start comes from media3's default `InAppMp4Muxer` on Android and `shouldOptimizeForNetworkUse` on iOS.

## 6. Post-rewrite review record (v0.1.0, `rewrite` branch — NOT merged)

A full second-pass review of the rewrite diff found and fixed:

- `_SliderMetrics.trackWidth` mixed `double`/`int` in `math.max` (inference to `num` → compile error under `strict-casts`). Fixed with a `double` literal.
- Android: if `Transformer.start()` threw synchronously, the export stayed registered → progress poller looped forever and a later `cancelExport` could answer the same `MethodChannel.Result` twice. Fixed by registering the export only after a guarded `start()`.
- A cancel-before-start race in `AmphitheatreExportSession` (cancel issued while the temp directory was being resolved was silently ignored). Fixed with an explicit pre-start check.
- Test hygiene for this repo's strict lints (unclosed `StreamController` in the fake platform; documented `public_member_api_docs` ignores in test files).

Known considerations (accepted, documented):

- iOS passthrough preset with `.mp4` output can fail for exotic `.mov` contents (e.g., ProRes, timecode tracks). The failure surfaces cleanly in the retry UI; selecting a transcoding quality is the workaround. A `supportedFileTypes` check with a `.mov` fallback could be added later.
- Android reads video metadata (height/rotation) on the platform thread before a transcode — header-only, milliseconds, accepted.
- Trim start snaps to the nearest sync frame in pure-passthrough scenarios on iOS; on Android, media3's trim optimization re-encodes only the first GOP for accurate starts.
- `example/test/widget_test.dart` is stale (pre-dates the rewrite; asserts "Running on:" text that the example never renders). Left untouched; worth replacing when the example is next revised.

Still to verify on a machine with the Flutter SDK: `flutter analyze`, `flutter test`, `flutter gen-l10n` (generated files were maintained by hand), an Android build against media3 `1.10.1` (confirm artifact resolves and `experimentalSetTrimOptimizationEnabled` still bears that name), an iOS `pod install`/build, and a real-device export of a multi-GB video on both platforms.

## 7. Final review (cross-layer audit + independent model review)

A final pass consisted of (a) a deterministic cross-layer contract audit — method names, event-channel name, argument keys, quality wire values, and all five error codes are identical across Dart, Kotlin, and Swift — and (b) an independent adversarial review of both native files by Gemini. Findings applied:

- **Input/output aliasing guard (both platforms):** the failure/cancel paths delete the output file, so if a caller ever passed the same path for input and output, the source video could have been destroyed. Both plugins now reject aliased paths with `ERR_BAD_PARAMS` (Android compares canonical paths; iOS compares standardized file URLs). Regression test added.
- **Android, audio-only inputs:** an unknown video height previously resolved to "very large," which attached a `Presentation` scaling effect even to files with no video track — a guaranteed export failure. Unknown height now resolves to "no scaling."
- **Android, engine re-attach:** the thumbnail executor was created once and shut down on detach, so a re-attached plugin instance would throw `RejectedExecutionException` forever. It is now created per attach and `shutdownNow()` on detach.
- **Android, hanging futures:** a catastrophic failure (e.g., `OutOfMemoryError`) on the thumbnail thread would have died silently, leaving the Dart future pending forever. The background block now catches `Throwable` and always answers the channel.
- **Android, rotated thumbnails:** the scaled-frame target box now uses display-orientation dimensions (the retriever returns rotation-applied frames).
- **iOS, corrupt/indefinite durations:** `getThumbnails` now guards against NaN/zero durations instead of generating invalid `CMTime`s.

Reviewed and deliberately **not** changed (Gemini flagged, evidence says fine): the `.positiveInfinity` end time (Apple documents zero→infinity as `timeRange`'s default "whole asset" sentinel, and the editor always sends both bounds anyway); `await session.export()` on the pre-18 branch (identical call shipped in v0.0.3 at iOS 13); strong `self` captures in export Tasks (a weak capture would silently drop the pending Flutter result — the brief retention until completion is the correct trade-off); per-export progress-poll lifetime (bounded by the export entry itself, stopped by completion or cancel).
