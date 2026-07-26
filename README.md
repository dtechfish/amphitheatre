# amphitheatre

A Flutter video player and editor.

<div align="center">
    <table>
        <tbody>
            <tr>
                <td align="center">
                    <img src="https://raw.githubusercontent.com/apollosoftwarexyz/amphitheatre/master/screenshots/player.png" width="256px" alt="Screenshot of player" />
                </td>
                <td align="center">
                    <img src="https://raw.githubusercontent.com/apollosoftwarexyz/amphitheatre/master/screenshots/editor.png" width="256px" alt="Screenshot of editor" />
                </td>
            </tr>
            <tr>
                <td align="center">
                    <a href="https://pub.dev/documentation/amphitheatre/latest/amphitheatre/Amphitheatre-class.html" target="_blank"><code>Amphitheatre</code></a>
                </td>
                <td align="center">
                    <a href="https://pub.dev/documentation/amphitheatre/latest/amphitheatre/AmphitheatreEditor-class.html" target="_blank"><code>AmphitheatreEditor</code></a>
                </td>
            </tr>
        </tbody>
    </table>
</div>

<table>
    <tbody>
        <tr>
            <td></td>
            <td><b>Android</b></td>
            <td><b>iOS</b></td>
        </tr>
        <tr>
            <td><b>Supported Versions</b></td>
            <td>SDK 23+ &dagger;</td>
            <td>13.0+ *</td>
        </tr>
        <tr>
            <td><b>Supported Devices<br/><small>(as of Jan 3, 2025)</small></b></td>
            <td><a href="https://web.archive.org/web/20241222230146/https://apilevels.com/" target="_blank">99.7%</a></td>
            <td><a href="https://web.archive.org/web/20250102215257/https://iosref.com/ios-usage" target="_blank">96.8%</a></td>
        </tr>
    </tbody>
</table>

<small>* NB: support for older versions can be implemented if needed, it has been omitted at present for simplicity of
the platform channel implementation.</small>

<small>&dagger; Raised from SDK 21 in v0.1.0: androidx.media3 1.10 (which powers exporting) enforces minSdk 23, per
the AndroidX baseline policy. Android 6.0 (2015) covers effectively all active devices.</small>

## Quick Start

First, refer to [Setup for the `video_player` package](https://pub.dev/packages/video_player#setup) to ensure the media
can be played from your desired source.

Then, construct an `Amphitheatre`. For convenience, you can use the `Amphitheatre.launch` function to simply launch a
new screen with the player:

```dart
/// Launches a screen with the Amphitheatre video player.
void showVideo({ required final File myVideo }) {
  Amphitheatre.launch(
    context,
    controller: AmphitheatreController(
      controller: VideoPlayerController.file(myVideo),
      info: AmphitheatreVideoInfo(
        title: "Title of the video",
        subtitle: "This is a subtitle.",
        description:
        "This is a long form description of the video. Lorem ipsum dolor sit amet.",
      ),
    ),
  );
}
```

...and similarly for the editor:

```dart
/// Launchers a screen with the Amphitheatre editor.
/// 
/// Returns a path to the output file (with the edited video)
/// on success, returns null on failure (or if the user closes
/// the screen without accepting changes).
Future<String?> editVideo({ required final File myVideo }) async {
  return await AmphitheatreEditor.launch(
    context,
    controller: AmphitheatreController(
      controller: VideoPlayerController.file(
        _chosenVideo!,
      ),
    ),
  );
}
```

Alternatively, you can either use `Amphitheatre.consume` to have Amphitheatre assume control of an `AmphitheatreController`
that you pass in - or you can simply use `Amphitheatre` with a controller that you manage as part of your own widget's
lifecycle (and likewise with the `AmphitheatreEditor`).

### Exporting and compression

The editor trims (and optionally compresses) with the platform's native media frameworks
([`androidx.media3` Transformer](https://developer.android.com/media/media3/transformer) on Android,
`AVAssetExportSession` on iOS). Video data is streamed — never loaded into memory — and the work runs off the UI
thread, so arbitrarily large videos are safe. Output is a fast-start (streamable) MP4 and the input file is never
modified or deleted.

Pick an export quality via the editor options:

```dart
AmphitheatreEditor.launch(
  context,
  controller: ...,
  options: const AmphitheatreEditorOptions(
    // `passthrough` (default) trims losslessly without re-encoding.
    // 2160p / 1080p / 720p transcode to H.264/AAC, scaling down if needed.
    exportQuality: AmphitheatreExportQuality.fhd1080,
  ),
);
```

You can also export directly, without the editor UI:

```dart
final session = AmphitheatreExporter.start(
  inputPath: myVideo.path,
  start: const Duration(seconds: 2),
  end: const Duration(seconds: 32),
  quality: AmphitheatreExportQuality.hd720,
);

session.progress.listen((progress) => debugPrint('${(progress * 100).round()}%'));

try {
  final outputPath = await session.result;
  // Upload/consume outputPath...
} on AmphitheatreExportException catch (e) {
  if (!e.wasCancelled) debugPrint('Export failed: ${e.code} ${e.message}');
}
```

### Localization (l10n) Support

This package has built-in support for `flutter_localizations`, with the long-term goal of getting any community-sourced
localizations merged into this repository so that applications can benefit from them automatically. (PRs welcome!)

We will provide our own 'official' localizations for the package if we write our own, which will be done on an
'as-needed' basis and will aim to review/merge community translations on a 'best-effort' basis.

To activate the library's localization, add the `AmphitheatreLocalization` delegate to your `MaterialApp`:

```dart
void main() {
  runApp(
    MaterialApp(
      home: const MyAppHome(),
      debugShowCheckedModeBanner: false,
      
      // Add this property:
      localizationsDelegates: [
        // This adds the AmphitheatreLocalizations delegate.
        AmphitheatreLocalizations.delegate,
        // This ensures you retain Flutter's built-in localization.
        // See here for details:
        // https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization
        ...GlobalMaterialLocalizations.delegates,
      ],
    ),
  );
}
```

## Development

### Adding translations

Don't forget to run the following command after updating any of the `.arb` files:

```bash
flutter gen-l10n
```
