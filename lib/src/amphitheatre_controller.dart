import 'dart:async';
import 'dart:typed_data';

import 'package:amphitheatre/src/amphitheatre.dart';
import 'package:amphitheatre/src/amphitheatre_platform.dart';
import 'package:amphitheatre/src/editor/amphitheatre_editor.dart';
import 'package:amphitheatre/src/utils.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// Stores non-technical information about the video.
/// See [AmphitheatreController.info].
class AmphitheatreVideoInfo {
  /// The title of the video.
  final String? title;

  /// The subtitle of the video.
  final String? subtitle;

  /// The video description.
  final String? description;

  /// Construct an [AmphitheatreVideoInfo] instance.
  const AmphitheatreVideoInfo({
    required this.title,
    required this.subtitle,
    required this.description,
  });

  List<Object?> get _nullableElements => [title, subtitle, description];

  /// Returns true if none of the video info elements are set.
  bool get isEmpty => _nullableElements.every((final item) => item == null);

  /// Returns true if any of the video info elements are set.
  bool get isNotEmpty => _nullableElements.any((final item) => item != null);
}

/// Controls the Amphitheatre video player.
class AmphitheatreController with ChangeNotifier {
  /// The controller for the underlying [VideoPlayer].
  final VideoPlayerController controller;

  /// Human-readable auxiliary information about the video. This can be used by
  /// components that display the video information, but it has no impact on the
  /// video itself (i.e., it is not technical metadata).
  ///
  /// If omitted, any components that display the [AmphitheatreVideoInfo] will
  /// not be rendered.
  final AmphitheatreVideoInfo? info;

  /// The duration to use for animations and transitions.
  Duration animationDuration;

  /// The curve to use for animations and transitions.
  Curve animationCurve;

  /// Construct the [AmphitheatreController].
  AmphitheatreController({
    required this.controller,
    this.info,
    this.animationDuration = const Duration(milliseconds: 200),
    this.animationCurve = Curves.easeInOut,
  });

  /// Returns true if the [info] is not null and the
  /// [AmphitheatreVideoInfo.isNotEmpty].
  bool get hasVideoInfo => info != null && info!.isNotEmpty;

  /// Returns whether the video has been completed.
  bool get isCompleted => controller.value.isCompleted;

  /// Returns whether the video is playing.
  bool get isPlaying => controller.value.isPlaying;

  /// Returns whether the video is buffering.
  bool get isBuffering => controller.value.isBuffering;

  /// Returns the greatest position that the player has buffered to, within the
  /// video. The value is clamped to the maximum duration of the video.
  ///
  /// If there is no data buffered (i.e., the list of buffers from the
  /// underlying [controller] is empty), this returns null.
  ///
  /// This is therefore a fairly simple heuristic that may be off if more
  /// advanced buffering logic is used internally.
  Duration? get buffered {
    final DurationRange? buffer = controller.value.buffered.lastOrNull;
    if (buffer == null) return null;

    return buffer.end > controller.value.duration
        ? controller.value.duration
        : buffer.end;
  }

  /// Returns the position of the player, within the video.
  Duration get position => controller.value.position;

  /// Returns the duration of the entire video.
  Duration get duration => controller.value.duration;

  /// Returns the formatted position of the player, within the video.
  String get formattedPosition => controller.value.position
      .format(hours: controller.value.duration.hasHours);

  /// Returns the formatted duration of the entire video.
  String get formattedDuration => controller.value.duration.format();

  /// Returns true when the underlying [controller] has been initialized. This
  /// is triggered by calling the [initialize] function on the
  /// [AmphitheatreController].
  bool get isInitialized => controller.value.isInitialized;

  /// If the underlying [controller] failed to initialize, holds the error
  /// that it failed with. Otherwise null.
  Object? get initializationError => _initializationError;
  Object? _initializationError;

  /// Returns true if the underlying [controller] failed to initialize.
  bool get hasInitializationError => _initializationError != null;

  /// Returns the aspect ratio of the video.
  double get aspectRatio => controller.value.aspectRatio;

  bool _initialized = false;

  /// Initialize the underlying [controller].
  ///
  /// If initialization fails, the failure is surfaced via
  /// [initializationError] and listeners are notified.
  void initialize({final bool autoPlay = true, final bool looping = false}) {
    // Ensure the controller is not re-initialized when it is already
    // initialized.
    if (_initialized) return;

    _initialized = true;
    _initializationError = null;

    controller.addListener(_onControllerUpdate);
    unawaited(controller.setLooping(looping));

    controller.initialize().then((final _) {
      if (autoPlay) play();
    }).catchError((final Object error) {
      _initializationError = error;
      notifyListeners();
    });
  }

  /// Instruct the [controller] to start playing the video.
  void play() => unawaited(controller.play());

  /// Instruct the [controller] to pause the video, whilst retaining the
  /// position.
  void pause() => unawaited(controller.pause());

  /// Instruct the [controller] to start playing the video from the start.
  void replay() => unawaited(
        controller.seekTo(Duration.zero).then((final _) => controller.play()),
      );

  /// Instruct the [controller] to seek by [delta], relative to the current
  /// position.
  void seek(final Duration delta) => seekTo(controller.value.position + delta);

  /// Instruct the [controller] to seek to the given [time].
  void seekTo(final Duration time) => unawaited(() async {
        if (controller.value.isCompleted) {
          await controller.play();
        }

        return controller.seekTo(time);
      }());

  void _onControllerUpdate() => notifyListeners();

  /// Dispose the underlying [controller], then the [AmphitheatreController].
  @override
  void dispose() {
    controller.removeListener(_onControllerUpdate);
    unawaited(controller.dispose());
    super.dispose();

    // As everything is now disposed, mark that the controller can be
    // re-initialized if desired.
    _initialized = false;
  }

  String? _materializedAssetPath;

  /// Resolves the path to the video file backing the underlying controller
  /// (e.g., so it can be exported by the [AmphitheatreEditor] or
  /// `AmphitheatreExporter`).
  ///
  /// The controller must have been initialized (see [initialize]), or this
  /// function throws a [StateError].
  ///
  /// For [DataSourceType.file] sources this simply resolves the path — no
  /// video data is read into memory. For [DataSourceType.asset] sources, the
  /// asset is copied once into Amphitheatre's temporary directory and the
  /// copy's path is returned. Other source types (e.g., network) are not
  /// supported: download the video to a file first and use
  /// [VideoPlayerController.file].
  Future<String> resolveVideoFilePath() async {
    if (!controller.value.isInitialized) {
      throw StateError('The controller has not been initialized yet.');
    }

    switch (controller.dataSourceType) {
      case DataSourceType.file:
        return Uri.parse(controller.dataSource).toFilePath();
      case DataSourceType.asset:
        if (_materializedAssetPath != null) return _materializedAssetPath!;

        final AmphitheatrePlatform platform = getAmphitheatrePlatform();

        // Asset keys are always delimited by forward slashes.
        final String name = controller.dataSource.split('/').last;
        final String path = platform.joinPath(
          await platform.getTemporaryDirectory(),
          'amphitheatre_asset_$name',
        );

        final ByteData data = await rootBundle.load(controller.dataSource);
        await XFile.fromData(data.buffer.asUint8List()).saveTo(path);
        return _materializedAssetPath = path;
      default:
        throw UnsupportedError(
          '[Amphitheatre] Unsupported data source type: '
          '${controller.dataSourceType}. Save the video to a file and use '
          'VideoPlayerController.file instead.',
        );
    }
  }
}
