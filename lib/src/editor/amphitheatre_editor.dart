import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui
    show Codec, FontFeature, Image, PictureRecorder, instantiateImageCodec;

import 'package:amphitheatre/amphitheatre.dart';
import 'package:amphitheatre/src/amphitheatre_platform.dart';
import 'package:amphitheatre/src/raw_asset_image.dart';
import 'package:amphitheatre/src/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

part 'amphitheatre_editor_controller.dart';

/// Editing options for the [AmphitheatreEditor].
@immutable
final class AmphitheatreEditorOptions {
  /// The minimum length that the video can be cropped to.
  final Duration minLength;

  /// The maximum length to allow the video to be.
  final Duration maxLength;

  /// When true, a video that is already no longer than [minLength] (and which
  /// therefore cannot be meaningfully cropped) is handled automatically when
  /// the editor opens instead of showing the editing UI: it is accepted as-is
  /// (popping with the video's path), unless [strict] is true.
  final bool autoAcceptShortVideos;

  /// Only relevant when [autoAcceptShortVideos] is true: a video that can
  /// never conform to [minLength] is rejected (the editor pops with null)
  /// instead of being accepted as-is.
  final bool strict;

  /// The quality to export the video with when the user accepts their
  /// changes. See [AmphitheatreExportQuality].
  final AmphitheatreExportQuality exportQuality;

  /// Construct the [AmphitheatreEditorOptions].
  const AmphitheatreEditorOptions({
    this.minLength = const Duration(seconds: 10),
    this.maxLength = const Duration(minutes: 5),
    this.autoAcceptShortVideos = false,
    this.strict = false,
    this.exportQuality = AmphitheatreExportQuality.passthrough,
  });

  /// Whether [autoAcceptShortVideos] applies to a video with the given
  /// [duration].
  bool shouldAutoAccept(final Duration duration) =>
      autoAcceptShortVideos && duration <= minLength;

  /// Returns the default start and end offsets for cropping. The offsets are
  /// based on computing the maximum length that can surround the middle of the
  /// video.
  (Duration start, Duration end) getDefaultOffsets(final Duration duration) {
    final int middleMilliseconds =
        (duration.inMilliseconds.toDouble() / 2).round();

    final int startMilliseconds =
        math.max(middleMilliseconds - (maxLength.inMilliseconds ~/ 2), 0);
    final int endMilliseconds = math.min(
      middleMilliseconds + (maxLength.inMilliseconds ~/ 2),
      duration.inMilliseconds,
    );

    return (
      Duration(milliseconds: startMilliseconds),
      Duration(milliseconds: endMilliseconds)
    );
  }

  @override
  bool operator ==(final Object other) =>
      other is AmphitheatreEditorOptions &&
      minLength == other.minLength &&
      maxLength == other.maxLength &&
      autoAcceptShortVideos == other.autoAcceptShortVideos &&
      strict == other.strict &&
      exportQuality == other.exportQuality;

  @override
  int get hashCode => Object.hash(
        minLength,
        maxLength,
        autoAcceptShortVideos,
        strict,
        exportQuality,
      );
}

/// Styling options for the [AmphitheatreEditor].
@immutable
final class AmphitheatreEditorStyle {
  /// The color to use when drawing the border around the playback slider.
  final Color borderColor;

  /// The radius to draw the corners of the playback slider with.
  final BorderRadius borderRadius;

  /// The thickness of the playback slider border.
  final double borderThickness;

  /// The color to use for the current progress (playhead) line on the
  /// playback slider.
  final Color lineColor;

  /// The thickness to draw the current progress line with.
  final double lineThickness;

  /// The color to use for the cropping handles and the selection frame.
  final Color cropColor;

  /// The width to use for the cropping handles.
  final double cropHandleSize;

  /// The color used to dim the parts of the timeline outside of the crop
  /// selection.
  final Color scrimColor;

  /// The fill color of the timeline track, visible until (and wherever)
  /// filmstrip thumbnails are not available.
  final Color trackColor;

  /// If specified, the [RawAssetImage] to paint on the crop start handle.
  final RawAssetImage? cropStartIcon;

  /// The color to paint the [cropStartIcon].
  final Color cropStartIconColor;

  /// If specified, the [RawAssetImage] to paint on the crop end handle.
  final RawAssetImage? cropEndIcon;

  /// The color to paint the [cropEndIcon].
  final Color cropEndIconColor;

  /// Construct an [AmphitheatreEditorStyle].
  const AmphitheatreEditorStyle({
    this.borderColor = Colors.white24,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.borderThickness = 2.0,
    this.lineColor = Colors.white,
    this.lineThickness = 2.5,
    this.cropColor = const Color(0xFFFFB300),
    this.cropHandleSize = 16.0,
    this.scrimColor = const Color(0x99000000),
    this.trackColor = const Color(0xFF15181D),
    this.cropStartIcon = const RawAssetImage(
      size: Size.square(20),
      assetPath: 'assets/crop_start.svg',
      package: 'amphitheatre',
    ),
    this.cropStartIconColor = Colors.black,
    this.cropEndIcon = const RawAssetImage(
      size: Size.square(20),
      assetPath: 'assets/crop_end.svg',
      package: 'amphitheatre',
    ),
    this.cropEndIconColor = Colors.black,
  });

  @override
  bool operator ==(final Object other) =>
      other is AmphitheatreEditorStyle &&
      borderColor == other.borderColor &&
      borderRadius == other.borderRadius &&
      borderThickness == other.borderThickness &&
      lineColor == other.lineColor &&
      lineThickness == other.lineThickness &&
      cropColor == other.cropColor &&
      cropHandleSize == other.cropHandleSize &&
      scrimColor == other.scrimColor &&
      trackColor == other.trackColor &&
      cropStartIcon == other.cropStartIcon &&
      cropStartIconColor == other.cropStartIconColor &&
      cropEndIcon == other.cropEndIcon &&
      cropEndIconColor == other.cropEndIconColor;

  @override
  int get hashCode => Object.hashAll([
        borderColor,
        borderRadius,
        borderThickness,
        lineColor,
        lineThickness,
        cropColor,
        cropHandleSize,
        scrimColor,
        trackColor,
        cropStartIcon,
        cropStartIconColor,
        cropEndIcon,
        cropEndIconColor,
      ]);
}

/// A builder for the [Route] that is used to open an [AmphitheatreEditor] when
/// [AmphitheatreEditor.launch] is called.
///
/// This can be used to customize the route and therefore the transition that is
/// used when an [AmphitheatreEditor] is launched.
typedef AmphitheatreEditorRouteBuilder = Route<String?> Function(Widget child);

Route<String?> _defaultAmphitheatreEditorRouteBuilder(final Widget child) =>
    MaterialPageRoute<String?>(builder: (final _) => child);

Widget _buildVideoControls(
  final AmphitheatreController controller,
  final bool showControls,
) =>
    AmphitheatreVideoControls(controller: controller);

/// The state of an in-progress (or failed) export, passed to
/// [AmphitheatreExporterProgressBuilder].
@immutable
final class AmphitheatreExportUiState {
  /// The progress of the export from `0.0` to `1.0`, or null when progress is
  /// indeterminate (not yet known, or not measurable for this export).
  final double? progress;

  /// The error the export failed with, or null while the export is running.
  final AmphitheatreExportException? error;

  /// Cancels the export (or, if [error] is set, returns to the editor).
  final VoidCallback onCancel;

  /// Retries a failed export. Only meaningful when [error] is set.
  final VoidCallback onRetry;

  /// Construct an [AmphitheatreExportUiState].
  const AmphitheatreExportUiState({
    required this.progress,
    required this.error,
    required this.onCancel,
    required this.onRetry,
  });
}

/// A builder for the screen rendered while the [AmphitheatreEditor] is
/// exporting the new video (and when the export fails).
typedef AmphitheatreExporterProgressBuilder = Widget Function(
  AmphitheatreExportUiState state,
);

Widget _buildAmphitheatreExporterProgress(
  final AmphitheatreExportUiState state,
) =>
    AmphitheatreExporterProgress(state: state);

/// The Amphitheatre video editor.
class AmphitheatreEditor extends StatefulWidget {
  /// The controller for the [Amphitheatre] player.
  final AmphitheatreController controller;

  /// Editing options for the [AmphitheatreEditor].
  final AmphitheatreEditorOptions options;

  /// Styling options for the [AmphitheatreEditor].
  final AmphitheatreEditorStyle style;

  /// {@macro amphitheatre_build_video_controls}
  final AmphitheatreComponentBuilder buildVideoControls;

  /// The exporter progress screen builder.
  final AmphitheatreExporterProgressBuilder buildExporterProgress;

  /// See [Amphitheatre.consumedController].
  final bool consumedController;

  /// The default constructor for [AmphitheatreEditor].
  const AmphitheatreEditor({
    required this.controller,
    this.style = const AmphitheatreEditorStyle(),
    this.options = const AmphitheatreEditorOptions(),
    this.buildVideoControls = _buildVideoControls,
    this.buildExporterProgress = _buildAmphitheatreExporterProgress,
    super.key,
  }) : consumedController = false;

  /// See [Amphitheatre.consume].
  const AmphitheatreEditor.consume({
    required this.controller,
    this.style = const AmphitheatreEditorStyle(),
    this.options = const AmphitheatreEditorOptions(),
    this.buildVideoControls = _buildVideoControls,
    this.buildExporterProgress = _buildAmphitheatreExporterProgress,
    super.key,
  }) : consumedController = true;

  /// Launches the [AmphitheatreEditor] with the given controller, consuming the
  /// controller. See [AmphitheatreEditor.consume].
  ///
  /// Various [AmphitheatreEditorOptions] can be supplied by supplying
  /// [options]. If these are not specified, default values are used instead.
  ///
  /// If you require further customization, such as the ability to supply custom
  /// widgets for buttons, etc., then you should directly use the
  /// [AmphitheatreEditor.consume] API instead (which consumes an
  /// [AmphitheatreController]) - this function is simply a wrapper around that
  /// API.
  ///
  /// When the [AmphitheatreEditor] pops, it either pops with null (if the user
  /// cancelled), or it pops with the path to the resulting video. Note that
  /// when no modifications were necessary, the resulting path may be the
  /// original input file itself — so do not assume the result is a new
  /// temporary file that can be freely deleted.
  static Future<String?> launch(
    final BuildContext context, {
    required final AmphitheatreController controller,
    final AmphitheatreEditorOptions options = const AmphitheatreEditorOptions(),
    final AmphitheatreEditorRouteBuilder routeBuilder =
        _defaultAmphitheatreEditorRouteBuilder,
    final bool useRootNavigator = false,
  }) async {
    final Widget child = AmphitheatreEditor.consume(
      controller: controller,
      options: options,
    );

    return Navigator.of(context, rootNavigator: useRootNavigator)
        .push<String?>(routeBuilder(child));
  }

  @override
  State<AmphitheatreEditor> createState() => _AmphitheatreEditorState();

  @override
  void debugFillProperties(final DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<AmphitheatreController>('controller', controller),
      )
      ..add(DiagnosticsProperty<AmphitheatreEditorStyle>('style', style))
      ..add(DiagnosticsProperty<AmphitheatreEditorOptions>('options', options))
      ..add(
        ObjectFlagProperty<AmphitheatreComponentBuilder>.has(
          'buildVideoControls',
          buildVideoControls,
        ),
      )
      ..add(
        ObjectFlagProperty<AmphitheatreExporterProgressBuilder>.has(
          'buildExporterProgress',
          buildExporterProgress,
        ),
      )
      ..add(
        DiagnosticsProperty<bool>('consumedController', consumedController),
      );
  }
}

class _AmphitheatreEditorState extends State<AmphitheatreEditor> {
  final AmphitheatreEditorController editorController =
      AmphitheatreEditorController();

  AmphitheatreExportSession? _exportSession;
  StreamSubscription<double>? _progressSubscription;
  double? _exportProgress;
  AmphitheatreExportException? _exportError;
  bool _exportRequested = false;
  bool _autoAcceptHandled = false;

  bool get _showExportScreen => _exportRequested || _exportError != null;

  @override
  void initState() {
    super.initState();
    editorController.addListener(_onEditorUpdate);
    widget.controller.addListener(_onControllerUpdate);

    if (widget.consumedController) {
      widget.controller.initialize(autoPlay: false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    editorController
      ..removeListener(_onEditorUpdate)
      ..dispose();

    unawaited(_progressSubscription?.cancel());

    // If the route is dismissed while an export is still running, abort it so
    // the platform can clean up its partial output.
    unawaited(_exportSession?.cancel());

    if (widget.consumedController) {
      widget.controller.dispose();
    }

    super.dispose();
  }

  void _onEditorUpdate() {
    if (mounted) setState(() {});
  }

  void _onControllerUpdate() => unawaited(_maybeAutoAccept());

  /// Handles [AmphitheatreEditorOptions.autoAcceptShortVideos] once the video
  /// has loaded.
  Future<void> _maybeAutoAccept() async {
    if (_autoAcceptHandled || !widget.controller.isInitialized) return;
    _autoAcceptHandled = true;

    if (!widget.options.shouldAutoAccept(widget.controller.duration)) return;

    final NavigatorState navigator = Navigator.of(context);
    if (widget.options.strict) {
      navigator.pop(null);
      return;
    }

    final String path = await widget.controller.resolveVideoFilePath();
    if (mounted) navigator.pop(path);
  }

  /// Whether the changes can be accepted. This is currently based on whether
  /// there is a crop set as even if the video is of acceptable length, the crop
  /// options initialize to that full length. (So it is only false when the
  /// editor has not fully initialized).
  bool get canAcceptChanges =>
      editorController.value.crop != null && !_showExportScreen;

  Future<void> _startExport() async {
    if (_exportSession != null) return;

    widget.controller.pause();
    final NavigatorState navigator = Navigator.of(context);

    setState(() {
      _exportRequested = true;
      _exportError = null;
      _exportProgress = null;
    });

    try {
      final String inputPath = await widget.controller.resolveVideoFilePath();

      // The user backed out before the export could begin.
      if (!mounted || !_exportRequested) return;

      final AmphitheatreEditorActionCrop? crop = editorController.value.crop;
      final Duration duration = widget.controller.duration;
      final bool needsTrim = crop != null &&
          (crop.start > Duration.zero || crop.end < duration);

      // Nothing to do: hand the original file back untouched.
      if (!needsTrim &&
          widget.options.exportQuality ==
              AmphitheatreExportQuality.passthrough) {
        navigator.pop(inputPath);
        return;
      }

      final AmphitheatreExportSession session = AmphitheatreExporter.start(
        inputPath: inputPath,
        start: needsTrim ? crop.start : null,
        end: needsTrim ? crop.end : null,
        quality: widget.options.exportQuality,
      );

      setState(() => _exportSession = session);

      _progressSubscription = session.progress.listen((final double value) {
        if (mounted) setState(() => _exportProgress = value);
      });

      final String outputPath = await session.result;
      if (mounted) navigator.pop(outputPath);
    } on AmphitheatreExportException catch (exception) {
      if (!mounted) return;
      setState(() {
        // A cancelled export simply returns to the editor; any other failure
        // shows the error state.
        _exportError = exception.wasCancelled ? null : exception;
        _exportRequested = false;
      });
    } on Object catch (exception) {
      if (!mounted) return;
      setState(() {
        _exportError = AmphitheatreExportException(
          code: AmphitheatreErrorCodes.exportFailed,
          message: exception.toString(),
        );
        _exportRequested = false;
      });
    } finally {
      unawaited(_progressSubscription?.cancel());
      _progressSubscription = null;
      _exportSession = null;
      _exportProgress = null;
    }
  }

  void _cancelExport() {
    final AmphitheatreExportSession? session = _exportSession;
    if (session != null) {
      unawaited(session.cancel());
    } else if (mounted) {
      setState(() {
        _exportRequested = false;
        _exportError = null;
      });
    }
  }

  void _retryExport() {
    if (!mounted) return;
    setState(() => _exportError = null);
    unawaited(_startExport());
  }

  @override
  Widget build(final BuildContext context) {
    if (_showExportScreen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (final bool didPop, final Object? _) {
          if (!didPop) _cancelExport();
        },
        child: widget.buildExporterProgress(
          AmphitheatreExportUiState(
            progress: _exportProgress,
            error: _exportError,
            onCancel: _cancelExport,
            onRetry: _retryExport,
          ),
        ),
      );
    }

    return Amphitheatre(
      controller: widget.controller,
      enableToggleControls: false,
      enableReplayButton: false,
      autoPlay: false,
      buildCloseButton: (final controller, final _) =>
          AmphitheatreCancelButton(controller: controller),
      buildVideoControls: widget.buildVideoControls,
      buildDoneButton: (final controller, final _) => AmphitheatreDoneButton(
        controller: controller,
        onPressed: canAcceptChanges
            ? (final _) => unawaited(_startExport())
            : null,
      ),
      buildProgressSlider: (final controller, final __) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AmphitheatreEditorSlider(
          controller: controller,
          editorController: editorController,
          options: widget.options,
          style: widget.style,
        ),
      ),
    );
  }

  @override
  void debugFillProperties(final DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<AmphitheatreEditorController>(
          'editorController',
          editorController,
        ),
      )
      ..add(DiagnosticsProperty<bool>('exporting', _showExportScreen))
      ..add(DiagnosticsProperty<bool>('canAcceptChanges', canAcceptChanges));
  }
}

/// The default exporter progress screen for the [AmphitheatreEditor].
///
/// While the export runs it renders a determinate progress ring with the
/// percentage (or an indeterminate ring when progress is unknown) and a
/// cancel action. When the export fails it explains what happened and offers
/// to retry or return to the editor.
class AmphitheatreExporterProgress extends StatelessWidget {
  /// The state of the export.
  final AmphitheatreExportUiState state;

  /// Construct the [AmphitheatreExporterProgress] screen.
  const AmphitheatreExporterProgress({
    required this.state,
    super.key,
  });

  @override
  Widget build(final BuildContext context) {
    final AmphitheatreLocalizations loc = getLocalizationDelegate(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: state.error != null
            ? _buildError(context, loc)
            : _buildProgress(context, loc),
      ),
    );
  }

  Widget _buildProgress(
    final BuildContext context,
    final AmphitheatreLocalizations loc,
  ) {
    final double? progress = state.progress;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: loc.exportingVideo(progress ?? 0),
                  child: SizedBox.square(
                    dimension: 96,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 3,
                          strokeCap: StrokeCap.round,
                          color: Colors.white,
                          backgroundColor: Colors.white12,
                        ),
                        if (progress != null)
                          Center(
                            child: Text(
                              loc.progressPercent(progress),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                fontFeatures: [
                                  ui.FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  loc.exportingVideoTitle,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextButton(
            onPressed: state.onCancel,
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            child: Text(loc.cancel),
          ),
        ),
      ],
    );
  }

  Widget _buildError(
    final BuildContext context,
    final AmphitheatreLocalizations loc,
  ) =>
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  loc.exportFailedTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  loc.exportFailedBody,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                if (state.error?.message case final String message) ...[
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: state.onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                  child: Text(loc.retry),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: state.onCancel,
                  style:
                      TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: Text(loc.backToEditor),
                ),
              ],
            ),
          ),
        ),
      );

  @override
  void debugFillProperties(final DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(
      DiagnosticsProperty<AmphitheatreExportUiState>('state', state),
    );
  }
}

enum _AmphitheatreEditorSliderDragMode {
  /// Just the playback head.
  playbackHead,

  /// The start crop handle.
  cropStart,

  /// The end crop handle.
  cropEnd,

  /// In-between the crop handles (the "intersection").
  cropIntersection;

  bool get isCropHandleOnly => this == cropStart || this == cropEnd;
  bool get isCrop => isCropHandleOnly || this == cropIntersection;

  bool get isCropStart => this == cropStart || this == cropIntersection;
  bool get isCropEnd => this == cropEnd || this == cropIntersection;
}

/// Geometry for the editor slider: the single source of truth for mapping
/// between video time (milliseconds) and x-positions on the track.
///
/// The track occupies the horizontal space between the two crop handle
/// gutters; positions returned by [positionFor] are in the slider's local
/// coordinate space.
@immutable
final class _SliderMetrics {
  final Size size;
  final AmphitheatreEditorStyle style;
  final int max;

  const _SliderMetrics({
    required this.size,
    required this.style,
    required this.max,
  });

  /// The width reserved on each side of the track for a crop handle.
  double get inset => style.cropHandleSize + style.borderThickness;

  double get trackLeft => inset;
  double get trackRight => size.width - inset;
  double get trackWidth => math.max(size.width - inset * 2, 1.0);

  Rect get trackRect => Rect.fromLTRB(trackLeft, 0, trackRight, size.height);

  RRect get trackRRect => RRect.fromRectAndCorners(
        trackRect,
        topLeft: style.borderRadius.topLeft,
        topRight: style.borderRadius.topRight,
        bottomLeft: style.borderRadius.bottomLeft,
        bottomRight: style.borderRadius.bottomRight,
      );

  /// The x-position on the track for the given time [value] (milliseconds).
  double positionFor(final int value) =>
      max <= 0 ? trackLeft : trackLeft + (value / max) * trackWidth;

  /// The time (milliseconds) for the given x-position on the track, clamped
  /// to the video bounds.
  int valueFor(final double dx) => max <= 0
      ? 0
      : (((dx - trackLeft) / trackWidth) * max).round().clamp(0, max);

  /// Converts a horizontal drag distance to a time delta (milliseconds).
  int deltaValueFor(final double dxDelta) =>
      max <= 0 ? 0 : ((dxDelta / trackWidth) * max).round();
}

/// The [AmphitheatreEditorSlider] is a [CustomPainter]-based timeline that
/// renders a filmstrip of the video with a playhead and handles for cropping
/// the video down to size, plus the start/end/selected-length timestamps.
class AmphitheatreEditorSlider extends StatefulWidget {
  /// The [controller] for the [Amphitheatre] player.
  final AmphitheatreController controller;

  /// The [AmphitheatreEditorController], containing information about the
  /// actions to be applied.
  final AmphitheatreEditorController editorController;

  /// Editing options for the [AmphitheatreEditor].
  final AmphitheatreEditorOptions options;

  /// Additional styling options for the slider.
  final AmphitheatreEditorStyle style;

  /// The height of the timeline track.
  final double height;

  /// Whether to render the filmstrip (thumbnails of the video) inside the
  /// track.
  final bool showFilmstrip;

  /// Whether to render the start/selected/end timestamps under the track.
  final bool showTimestamps;

  /// Construct the [AmphitheatreEditorSlider].
  const AmphitheatreEditorSlider({
    required this.controller,
    required this.editorController,
    required this.options,
    required this.style,
    this.height = 64,
    this.showFilmstrip = true,
    this.showTimestamps = true,
    super.key,
  });

  @override
  State<AmphitheatreEditorSlider> createState() =>
      _AmphitheatreEditorSliderState();

  @override
  void debugFillProperties(final DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(
        DiagnosticsProperty<AmphitheatreController>('controller', controller),
      )
      ..add(
        DiagnosticsProperty<AmphitheatreEditorController>(
          'editorController',
          editorController,
        ),
      )
      ..add(DiagnosticsProperty<AmphitheatreEditorOptions>('options', options))
      ..add(DiagnosticsProperty<AmphitheatreEditorStyle>('style', style))
      ..add(DoubleProperty('height', height))
      ..add(DiagnosticsProperty<bool>('showFilmstrip', showFilmstrip))
      ..add(DiagnosticsProperty<bool>('showTimestamps', showTimestamps));
  }
}

class _AmphitheatreEditorSliderState extends State<AmphitheatreEditorSlider> {
  /// The cached start (LHS) crop icon.
  ui.Image? _cropStartIcon;

  /// The cached end (RHS) crop icon.
  ui.Image? _cropEndIcon;

  /// The filmstrip thumbnails, in timeline order.
  List<ui.Image> _thumbnails = const [];
  bool _thumbnailsRequested = false;

  /// The [_AmphitheatreEditorSliderDragMode] of the current 'drag session'.
  _AmphitheatreEditorSliderDragMode? _dragMode;

  /// The offset at which the user started dragging.
  Offset? _dragLocalOffset;

  Duration? _cachedCropStart;
  Duration? _cachedCropEnd;

  /// The last time the slider issued an automatic (non-user) seek; used to
  /// avoid flooding the player with seek requests.
  DateTime _lastAutoSeek = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_loadImages());

    widget.controller.addListener(_didVideoLoad);
    widget.editorController.addListener(_didEditVideo);
  }

  @override
  void dispose() {
    widget.editorController.removeListener(_didEditVideo);
    widget.controller.removeListener(_didControllerUpdate);
    widget.controller.removeListener(_didVideoLoad);
    _cropStartIcon?.dispose();
    _cropEndIcon?.dispose();
    _cropStartIcon = null;
    _cropEndIcon = null;
    for (final ui.Image thumbnail in _thumbnails) {
      thumbnail.dispose();
    }
    _thumbnails = const [];
    super.dispose();
  }

  /// A handler to be invoked once when the video loads. The handler will remove
  /// itself automatically once successfully invoked.
  void _didVideoLoad() {
    if (widget.controller.isInitialized &&
        widget.editorController.value.crop == null) {
      final (Duration initialStart, Duration initialEnd) =
          widget.options.getDefaultOffsets(widget.controller.duration);
      widget.editorController
        ..crop(start: initialStart, end: initialEnd)
        ..markInitial();

      _ensurePlaybackWithinCropRegion(force: true);
      widget.controller.play();
      widget.controller.removeListener(_didVideoLoad);
      widget.controller.addListener(_didControllerUpdate);
    }
  }

  void _didControllerUpdate() {
    if (widget.controller.isInitialized &&
        widget.editorController.value.crop != null) {
      _ensurePlaybackWithinCropRegion();
    }
    if (mounted) setState(() {});
  }

  void _didEditVideo() {
    if (mounted) setState(() {});
  }

  /// Ensures that the playback head always resides within the crop region.
  ///
  /// Automatic seeks are throttled so that continuous position updates (or
  /// crop handle movement) do not flood the underlying player with seek
  /// requests.
  void _ensurePlaybackWithinCropRegion({final bool force = false}) {
    final AmphitheatreEditorActionCrop? crop =
        widget.editorController.value.crop;
    if (crop == null) return;

    final Duration position = widget.controller.position;
    final bool isPlaying = widget.controller.isPlaying;

    Duration? target;
    if (position < crop.start) {
      target = crop.start;
    } else if (position > crop.end) {
      // Loop back to the start of the selection during playback; clamp to the
      // end of the selection while paused.
      target = isPlaying ? crop.start : crop.end;
    }

    if (target != null) _autoSeek(target, force: force);
  }

  void _autoSeek(final Duration target, {final bool force = false}) {
    final DateTime now = DateTime.now();
    if (!force && now.difference(_lastAutoSeek).inMilliseconds < 200) return;

    _lastAutoSeek = now;
    widget.controller.seekTo(target);
  }

  @override
  void didUpdateWidget(final AmphitheatreEditorSlider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.style.cropStartIcon != widget.style.cropStartIcon ||
        oldWidget.style.cropEndIcon != widget.style.cropEndIcon) {
      unawaited(_loadImages());
    }
  }

  static Future<ui.Image> _loadRawAssetImage(final RawAssetImage image) async {
    if (!image.size.isFinite) {
      throw ArgumentError('RawAssetImage size must be finite.', 'size');
    }

    final imageBuffer =
        Uint8List.view((await rootBundle.load(image.path)).buffer);

    if (image.assetPath.endsWith('.svg')) {
      final PictureInfo picture =
          await vg.loadPicture(SvgStringLoader(utf8.decode(imageBuffer)), null);

      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
        Offset.zero & Size(image.size.width, image.size.height),
      )
        ..scale(
          image.size.width.roundToDouble() / picture.size.width,
          image.size.height.roundToDouble() / picture.size.height,
        )
        ..drawPicture(picture.picture);

      final ui.Image decodedImage = await recorder.endRecording().toImage(
            image.size.width.round(),
            image.size.height.round(),
          );

      picture.picture.dispose();
      return decodedImage;
    } else {
      final ui.Codec codec = await ui.instantiateImageCodec(
        imageBuffer,
        targetWidth: image.size.width.round(),
        targetHeight: image.size.height.round(),
        allowUpscaling: true,
      );

      return (await codec.getNextFrame()).image;
    }
  }

  Future<void> _loadImages() async {
    if (widget.style.cropStartIcon != null) {
      try {
        _cropStartIcon = await _loadRawAssetImage(widget.style.cropStartIcon!);
      } catch (_) {/* ignored */}
    }

    if (widget.style.cropEndIcon != null) {
      try {
        _cropEndIcon = await _loadRawAssetImage(widget.style.cropEndIcon!);
      } catch (_) {/* ignored */}
    }

    if (mounted) setState(() {});
  }

  /// Requests filmstrip thumbnails from the platform, once, sized for the
  /// given track [size].
  ///
  /// The filmstrip is a progressive enhancement: any failure (e.g., an
  /// unsupported data source) simply leaves the plain track visible.
  Future<void> _maybeLoadThumbnails(final Size size) async {
    if (!widget.showFilmstrip ||
        _thumbnailsRequested ||
        !widget.controller.isInitialized ||
        widget.controller.duration <= Duration.zero) {
      return;
    }
    _thumbnailsRequested = true;

    try {
      final double aspectRatio =
          widget.controller.aspectRatio.isFinite &&
                  widget.controller.aspectRatio > 0
              ? widget.controller.aspectRatio.clamp(0.4, 2.4)
              : 1.0;

      final int count =
          (size.width / (size.height * aspectRatio)).ceil().clamp(3, 24);
      final double devicePixelRatio =
          mounted ? MediaQuery.devicePixelRatioOf(context) : 1.0;
      final int maxHeight =
          (size.height * devicePixelRatio).round().clamp(32, 320);

      final String path = await widget.controller.resolveVideoFilePath();
      final List<Uint8List> encoded =
          await getAmphitheatrePlatform().getThumbnails(
        path: path,
        count: count,
        maxHeight: maxHeight,
      );

      final List<ui.Image> thumbnails = [];
      for (final Uint8List bytes in encoded) {
        final ui.Codec codec = await ui.instantiateImageCodec(bytes);
        thumbnails.add((await codec.getNextFrame()).image);
        codec.dispose();
      }

      if (mounted) {
        setState(() => _thumbnails = thumbnails);
      } else {
        for (final ui.Image thumbnail in thumbnails) {
          thumbnail.dispose();
        }
      }
    } catch (_) {/* ignored: the filmstrip is optional */}
  }

  int get _max => widget.controller.duration.inMilliseconds;

  void _processInteraction(
    final Size size, {
    required final Offset localPosition,
    final bool isStart = false,
    final bool isEnd = false,

    /// Whether the interaction is a simple tap rather than a drag.
    final bool isTap = false,
  }) {
    final metrics =
        _SliderMetrics(size: size, style: widget.style, max: _max);

    if (isStart && _dragMode == null) {
      _dragMode = _computeDragMode(localPosition, metrics: metrics);
      _dragLocalOffset = localPosition;
      _cachedCropStart = widget.editorController.value.crop?.start;
      _cachedCropEnd = widget.editorController.value.crop?.end;

      // Pause while adjusting the crop so the preview follows the handle.
      if (_dragMode?.isCrop ?? false) widget.controller.pause();
    }

    if (_dragMode == _AmphitheatreEditorSliderDragMode.playbackHead ||
        (_dragMode == _AmphitheatreEditorSliderDragMode.cropIntersection &&
            isTap) ||
        (_dragMode == _AmphitheatreEditorSliderDragMode.cropIntersection &&
            _cachedCropStart == Duration.zero &&
            _cachedCropEnd == widget.controller.duration)) {
      _handleNewPlayerPosition(
        metrics,
        localPosition: localPosition,
        pauseBefore: isStart,
        playAfter: isEnd,
      );
    } else if ((_dragMode?.isCrop ?? false) &&
        _dragLocalOffset != null &&
        _cachedCropStart != null &&
        _cachedCropEnd != null) {
      _handleNewCropPosition(
        metrics,
        dragMode: _dragMode!,
        localPosition: localPosition,
        localOrigin: _dragLocalOffset!,
      );
    }

    if (isEnd) {
      widget.editorController.commitPending();
      _dragMode = null;
      _dragLocalOffset = null;
      _cachedCropStart = null;
      _cachedCropEnd = null;
    }
  }

  void _handleNewCropPosition(
    final _SliderMetrics metrics, {
    required final _AmphitheatreEditorSliderDragMode dragMode,
    required final Offset localPosition,
    required final Offset localOrigin,
  }) {
    final Duration duration = widget.controller.duration;
    final int durationMilliseconds = duration.inMilliseconds;

    final dragOffset = Duration(
      milliseconds:
          metrics.deltaValueFor(localPosition.dx - localOrigin.dx),
    );

    Duration cropStart = dragMode.isCropStart
        ? Duration(
            milliseconds: (_cachedCropStart! + dragOffset)
                .inMilliseconds
                .clamp(0, durationMilliseconds),
          )
        : _cachedCropStart!;

    Duration cropEnd = dragMode.isCropEnd
        ? Duration(
            milliseconds: (_cachedCropEnd! + dragOffset)
                .inMilliseconds
                .clamp(0, durationMilliseconds),
          )
        : _cachedCropEnd!;

    // Measure the difference between the cached times and likewise for the new
    // times.
    final Duration cachedDiff = _cachedCropEnd! - _cachedCropStart!;
    final Duration diff = cropEnd - cropStart;

    if (dragMode == _AmphitheatreEditorSliderDragMode.cropIntersection) {
      if (diff != cachedDiff) {
        // If the difference has changed, but we're in intersection mode,
        // re-compute the correct end value such that the difference remains.
        if (dragOffset.isNegative) {
          cropEnd = cropStart + cachedDiff;
        } else {
          cropStart = cropEnd - cachedDiff;
        }
      }
    } else if (dragMode.isCropHandleOnly) {
      if (diff >= widget.options.maxLength) {
        // If the maximum difference has been exceeded, 'drag' the other end
        // such that the maximum length is maintained.
        if (dragMode.isCropStart) {
          cropEnd = cropStart + widget.options.maxLength;
        } else {
          cropStart = cropEnd - widget.options.maxLength;
        }
      } else if (diff >= widget.options.minLength) {
        // Alternatively, reset the other end to where it would have been.
        // (This ensures it returns to the correct place if the user amends
        // their selection to be less than the maximum length after it was equal
        // to or exceeded the max length).
        if (dragMode.isCropStart) {
          cropEnd = _cachedCropEnd!;
        } else {
          cropStart = _cachedCropStart!;
        }
      } else {
        // If the difference is less than the minimum difference, similarly
        // adjust the other handle.
        if (dragMode.isCropStart) {
          cropEnd = cropStart + widget.options.minLength;

          if (cropEnd >= duration) {
            cropStart = duration - widget.options.minLength;
            cropEnd = duration;
          }
        } else {
          cropStart = cropEnd - widget.options.minLength;

          if (cropStart <= Duration.zero) {
            cropStart = Duration.zero;
            cropEnd = widget.options.minLength;
          }
        }
      }
    }

    widget.editorController
        .crop(start: cropStart, end: cropEnd, commit: false);

    // Preview the frame under the handle being dragged.
    _autoSeek(dragMode.isCropEnd && !dragMode.isCropStart
        ? cropEnd
        : cropStart);
  }

  void _handleNewPlayerPosition(
    final _SliderMetrics metrics, {
    required final Offset localPosition,
    final bool pauseBefore = false,
    final bool playAfter = false,
  }) {
    if (pauseBefore) {
      widget.controller.pause();
    }

    widget.controller.seekTo(
      Duration(milliseconds: metrics.valueFor(localPosition.dx)),
    );

    if (playAfter) {
      widget.controller.play();
    }
  }

  _AmphitheatreEditorSliderDragMode _computeDragMode(
    final Offset position, {
    required final _SliderMetrics metrics,
  }) =>
      _AmphitheatreEditorSliderCropPainter.computeCropDragMode(
        position,
        metrics: metrics,
        cropStart:
            widget.editorController.value.crop?.start.inMilliseconds,
        cropEnd: widget.editorController.value.crop?.end.inMilliseconds,
      ) ??
      _AmphitheatreEditorSliderDragMode.playbackHead;

  static const TextStyle _timestampStyle = TextStyle(
    color: Colors.white70,
    fontSize: 12,
    fontFeatures: [ui.FontFeature.tabularFigures()],
  );

  Widget _buildTimestamps(final BuildContext context) {
    final AmphitheatreEditorActionCrop? crop =
        widget.editorController.value.crop;
    if (!widget.showTimestamps ||
        crop == null ||
        !widget.controller.isInitialized) {
      return const SizedBox.shrink();
    }

    final bool hours = widget.controller.duration.hasHours;

    return Padding(
      padding: EdgeInsets.only(
        top: 8,
        left: widget.style.cropHandleSize,
        right: widget.style.cropHandleSize,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(crop.start.format(hours: hours), style: _timestampStyle),
          Text(
            getLocalizationDelegate(context)
                .selectedDuration((crop.end - crop.start).format()),
            style: _timestampStyle.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(crop.end.format(hours: hours), style: _timestampStyle),
        ],
      ),
    );
  }

  @override
  Widget build(final BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.all(widget.style.borderThickness / 2),
            child: SizedBox.fromSize(
              size: Size.fromHeight(widget.height),
              child: LayoutBuilder(
                builder: (final context, final constraints) {
                  final size =
                      Size(constraints.maxWidth, constraints.maxHeight);

                  unawaited(_maybeLoadThumbnails(size));

                  return GestureDetector(
                    onTapDown: (final details) => _processInteraction(
                      size,
                      localPosition: details.localPosition,
                      isStart: true,
                      // We can't use isTap here because we don't know if it's
                      // a tap or not!
                    ),
                    onTapUp: (final details) => _processInteraction(
                      size,
                      localPosition: details.localPosition,
                      isEnd: true,
                      isTap: true,
                    ),
                    onHorizontalDragStart: (final details) =>
                        _processInteraction(
                      size,
                      localPosition: details.localPosition,
                      isStart: true,
                    ),
                    onHorizontalDragUpdate: (final details) =>
                        _processInteraction(
                      size,
                      localPosition: details.localPosition,
                    ),
                    onHorizontalDragEnd: (final details) =>
                        _processInteraction(
                      size,
                      localPosition: details.localPosition,
                      isEnd: true,
                    ),
                    child: CustomPaint(
                      willChange: true,
                      size: size,
                      painter: _AmphitheatreEditorSliderPainter(
                        style: widget.style,
                        value: widget.controller.position.inMilliseconds,
                        max: _max,
                        thumbnails: _thumbnails,
                      ),
                      foregroundPainter:
                          (widget.editorController.value.crop != null)
                              ? _AmphitheatreEditorSliderCropPainter(
                                  size: size,
                                  style: widget.style,
                                  cropStart: widget.editorController.value
                                      .crop!.start.inMilliseconds,
                                  cropEnd: widget.editorController.value
                                      .crop!.end.inMilliseconds,
                                  max: _max,
                                  cropStartIcon: _cropStartIcon,
                                  cropEndIcon: _cropEndIcon,
                                )
                              : null,
                    ),
                  );
                },
              ),
            ),
          ),
          _buildTimestamps(context),
        ],
      );
}

class _AmphitheatreEditorSliderPainter extends CustomPainter {
  final int value;
  final int max;
  final AmphitheatreEditorStyle style;
  final List<ui.Image> thumbnails;

  const _AmphitheatreEditorSliderPainter({
    required this.value,
    required this.max,
    required this.style,
    required this.thumbnails,
  });

  @override
  bool operator ==(final Object other) =>
      other is _AmphitheatreEditorSliderPainter &&
      value == other.value &&
      max == other.max &&
      style == other.style &&
      listEquals(thumbnails, other.thumbnails);

  @override
  int get hashCode =>
      Object.hashAll([value, max, style, Object.hashAll(thumbnails)]);

  @override
  bool shouldRepaint(final _AmphitheatreEditorSliderPainter old) => old != this;

  @override
  void paint(final Canvas canvas, final Size size) {
    final metrics = _SliderMetrics(size: size, style: style, max: max);
    final RRect trackRRect = metrics.trackRRect;

    canvas
      ..save()
      ..clipRRect(trackRRect)
      ..drawRect(metrics.trackRect, Paint()..color = style.trackColor);

    _paintFilmstrip(canvas, metrics);

    if (max > 0) {
      final double linePosition = metrics.positionFor(value);

      // A subtle halo keeps the playhead visible over light frames.
      canvas
        ..drawLine(
          Offset(linePosition, 0),
          Offset(linePosition, size.height),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = style.lineThickness + 2
            ..color = Colors.black26,
        )
        ..drawLine(
          Offset(linePosition, 0),
          Offset(linePosition, size.height),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = style.lineThickness
            ..strokeCap = StrokeCap.round
            ..color = style.lineColor,
        );
    }

    canvas
      ..restore()
      ..drawRRect(
        trackRRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.borderThickness
          ..color = style.borderColor,
      );
  }

  /// Paints the filmstrip thumbnails in equal cells across the track, each
  /// cover-fitted (centered and cropped) into its cell.
  void _paintFilmstrip(final Canvas canvas, final _SliderMetrics metrics) {
    if (thumbnails.isEmpty) return;

    final double cellWidth = metrics.trackWidth / thumbnails.length;
    final double cellHeight = metrics.size.height;
    final Paint paint = Paint()..filterQuality = FilterQuality.low;

    for (int i = 0; i < thumbnails.length; i++) {
      final ui.Image image = thumbnails[i];
      final Rect cell = Rect.fromLTWH(
        metrics.trackLeft + i * cellWidth,
        0,
        cellWidth,
        cellHeight,
      );

      final double imageWidth = image.width.toDouble();
      final double imageHeight = image.height.toDouble();
      final double scale = math.max(
        cell.width / imageWidth,
        cell.height / imageHeight,
      );
      final double sourceWidth = cell.width / scale;
      final double sourceHeight = cell.height / scale;
      final Rect source = Rect.fromLTWH(
        (imageWidth - sourceWidth) / 2,
        (imageHeight - sourceHeight) / 2,
        sourceWidth,
        sourceHeight,
      );

      canvas.drawImageRect(image, source, cell, paint);
    }
  }
}

class _AmphitheatreEditorSliderCropPainter extends CustomPainter {
  final Size size;
  final AmphitheatreEditorStyle style;

  final int cropStart;
  final int cropEnd;
  final int max;

  final ui.Image? cropStartIcon;
  final ui.Image? cropEndIcon;

  const _AmphitheatreEditorSliderCropPainter({
    required this.size,
    required this.style,
    required this.cropStart,
    required this.cropEnd,
    required this.max,
    required this.cropStartIcon,
    required this.cropEndIcon,
  });

  @override
  bool operator ==(final Object other) =>
      other is _AmphitheatreEditorSliderCropPainter &&
      size == other.size &&
      style == other.style &&
      cropStart == other.cropStart &&
      cropEnd == other.cropEnd &&
      max == other.max &&
      cropStartIcon == other.cropStartIcon &&
      cropEndIcon == other.cropEndIcon;

  @override
  int get hashCode => Object.hashAll(
        [size, style, cropStart, cropEnd, max, cropStartIcon, cropEndIcon],
      );

  @override
  bool shouldRepaint(final _AmphitheatreEditorSliderCropPainter old) =>
      old != this;

  /// Compute the [_AmphitheatreEditorSliderDragMode] of a drag action at the
  /// given [position].
  ///
  /// If [cropStart] and [cropEnd] are null (e.g., because the crop state has
  /// not yet been initialized) this function always returns null to indicate
  /// that a crop action should not be performed.
  static _AmphitheatreEditorSliderDragMode? computeCropDragMode(
    final Offset position, {
    required final _SliderMetrics metrics,
    required final int? cropStart,
    required final int? cropEnd,
  }) {
    if (cropStart == null || cropEnd == null) return null;

    final double startPosition = metrics.positionFor(cropStart);
    final double endPosition = metrics.positionFor(cropEnd);
    final double handleWidth = metrics.inset;
    final double height = metrics.size.height;

    final Rect leftHandle = Rect.fromLTWH(
      startPosition - handleWidth,
      0,
      handleWidth,
      height,
    );
    if (leftHandle.contains(position)) {
      return _AmphitheatreEditorSliderDragMode.cropStart;
    }

    final Rect rightHandle =
        Rect.fromLTWH(endPosition, 0, handleWidth, height);
    if (rightHandle.contains(position)) {
      return _AmphitheatreEditorSliderDragMode.cropEnd;
    }

    final Rect intersection = Rect.fromLTRB(
      startPosition,
      0,
      endPosition,
      height,
    );
    if (intersection.contains(position)) {
      return _AmphitheatreEditorSliderDragMode.cropIntersection;
    }

    return null;
  }

  @override
  bool? hitTest(final Offset position) {
    final _AmphitheatreEditorSliderDragMode? cropDragMode = computeCropDragMode(
      position,
      metrics: _SliderMetrics(size: size, style: style, max: max),
      cropStart: cropStart,
      cropEnd: cropEnd,
    );

    if (cropDragMode?.isCrop ?? false) {
      return true;
    }

    return super.hitTest(position);
  }

  @override
  void paint(final Canvas canvas, final Size size) {
    if (this.size != size) {
      throw ArgumentError(
        [
          'Inconsistent sizes provided to _AmphitheatreEditorSliderCropPainter.',
          '',
          'The provided size and rendered size must match to ensure the correct hitTest semantics are applied.',
          '',
          'The easiest way to fix this is to wrap the _AmphitheatreEditorSliderCropPainter in a LayoutBuilder and pass the constraints down as a Size.',
        ].join('\n'),
        'size',
      );
    }

    if (max <= 0) return;

    final metrics = _SliderMetrics(size: size, style: style, max: max);
    final double startPosition = metrics.positionFor(cropStart);
    final double endPosition = metrics.positionFor(cropEnd);
    final double handleWidth = metrics.inset;

    // Dim the parts of the timeline outside of the selection.
    final Paint scrimPaint = Paint()..color = style.scrimColor;
    canvas
      ..save()
      ..clipRRect(metrics.trackRRect)
      ..drawRect(
        Rect.fromLTRB(metrics.trackLeft, 0, startPosition, size.height),
        scrimPaint,
      )
      ..drawRect(
        Rect.fromLTRB(endPosition, 0, metrics.trackRight, size.height),
        scrimPaint,
      )
      ..restore();

    final Paint cropFill = Paint()..color = style.cropColor;

    // The selection frame: thin bars along the top and bottom edges between
    // the handles.
    final double frameThickness = style.borderThickness;
    canvas
      ..drawRect(
        Rect.fromLTWH(
          startPosition,
          0,
          endPosition - startPosition,
          frameThickness,
        ),
        cropFill,
      )
      ..drawRect(
        Rect.fromLTWH(
          startPosition,
          size.height - frameThickness,
          endPosition - startPosition,
          frameThickness,
        ),
        cropFill,
      );

    // The crop handles, with the outer corners rounded to match the track.
    final RRect leftHandle = RRect.fromRectAndCorners(
      Rect.fromLTWH(startPosition - handleWidth, 0, handleWidth, size.height),
      topLeft: style.borderRadius.topLeft,
      bottomLeft: style.borderRadius.bottomLeft,
    );
    final RRect rightHandle = RRect.fromRectAndCorners(
      Rect.fromLTWH(endPosition, 0, handleWidth, size.height),
      topRight: style.borderRadius.topRight,
      bottomRight: style.borderRadius.bottomRight,
    );

    canvas
      ..drawRRect(leftHandle, cropFill)
      ..drawRRect(rightHandle, cropFill);

    _paintHandleIcon(
      canvas,
      icon: cropStartIcon,
      color: style.cropStartIconColor,
      handle: leftHandle.outerRect,
    );
    _paintHandleIcon(
      canvas,
      icon: cropEndIcon,
      color: style.cropEndIconColor,
      handle: rightHandle.outerRect,
    );
  }

  void _paintHandleIcon(
    final Canvas canvas, {
    required final ui.Image? icon,
    required final Color color,
    required final Rect handle,
  }) {
    if (icon == null) return;

    canvas.drawImage(
      icon,
      Offset(
        handle.center.dx - icon.width / 2,
        handle.center.dy - icon.height / 2,
      ),
      Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
