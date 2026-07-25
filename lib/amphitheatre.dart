/// A Flutter video player and editor.
///
/// The package is organized in four layers, from highest to lowest level:
///
/// * `Amphitheatre` — the full-screen video player widget.
/// * `AmphitheatreEditor` — the trim editor, built on top of the player,
///   which pops with the path to the exported video.
/// * `AmphitheatreExporter` — path-based video export (trimming and optional
///   compression) with progress reporting and cancellation. Usable directly,
///   without any of the UI.
/// * `AmphitheatrePlatform` — the platform interface, implemented natively
///   with androidx.media3 Transformer on Android and AVAssetExportSession on
///   iOS.
///
/// Video data is never loaded into memory and the native pipelines stream on
/// background threads, so arbitrarily large files are safe to process.
library;

export 'src/amphitheatre.dart';
export 'src/amphitheatre_components.dart';
export 'src/amphitheatre_controller.dart';
export 'src/amphitheatre_export.dart';
export 'src/amphitheatre_platform.dart'
    show
        AmphitheatreErrorCodes,
        AmphitheatreExportProgressEvent,
        AmphitheatreExportQuality,
        AmphitheatrePlatform,
        setAmphitheatrePlatform;
export 'src/editor/amphitheatre_editor.dart';
export 'src/l10n/amphitheatre_localizations.dart';
