import 'dart:async';

import 'package:amphitheatre/src/amphitheatre_platform.dart';
import 'package:flutter/services.dart';

/// An error that occurred whilst exporting a video.
final class AmphitheatreExportException implements Exception {
  /// One of the [AmphitheatreErrorCodes] values.
  final String code;

  /// A human-readable description of the underlying platform error, if one
  /// was provided.
  final String? message;

  /// Construct an [AmphitheatreExportException].
  const AmphitheatreExportException({required this.code, this.message});

  /// True when the export failed because it was cancelled with
  /// [AmphitheatreExportSession.cancel].
  bool get wasCancelled => code == AmphitheatreErrorCodes.cancelled;

  @override
  String toString() =>
      'AmphitheatreExportException($code${message != null ? ': $message' : ''})';
}

/// A handle to a running (or finished) video export.
///
/// Obtain one with [AmphitheatreExporter.start]. Listen to [progress] to
/// display progress, await [result] for the output file path, and call
/// [cancel] to abort the export.
final class AmphitheatreExportSession {
  /// The unique identifier of this export.
  final String id;

  final Completer<String> _result = Completer<String>();
  final StreamController<double> _progress = StreamController<double>.broadcast();

  StreamSubscription<AmphitheatreExportProgressEvent>? _progressSubscription;
  bool _cancelRequested = false;

  /// The progress of the export as a broadcast stream of values from `0.0` to
  /// `1.0`.
  ///
  /// Platforms may be unable to measure progress for some exports (e.g., a
  /// passthrough remux); in that case no progress events are emitted before
  /// completion and a UI should render an indeterminate state.
  Stream<double> get progress => _progress.stream;

  /// Completes with the path to the exported file, or completes with an
  /// [AmphitheatreExportException] on failure (including cancellation).
  ///
  /// The output file is written to Amphitheatre's temporary directory. The
  /// caller owns the output file; the input file is never modified or
  /// deleted.
  Future<String> get result => _result.future;

  /// Whether the export has finished (successfully or not).
  bool get isComplete => _result.isCompleted;

  AmphitheatreExportSession._(this.id);

  /// Request cancellation of the export.
  ///
  /// [result] completes with an [AmphitheatreExportException] whose
  /// [AmphitheatreExportException.wasCancelled] is true once the platform has
  /// aborted the export and cleaned up its partial output.
  Future<void> cancel() async {
    if (isComplete || _cancelRequested) return;
    _cancelRequested = true;
    await getAmphitheatrePlatform().cancelExport(id);
  }

  Future<void> _run({
    required final String inputPath,
    required final Duration? start,
    required final Duration? end,
    required final AmphitheatreExportQuality quality,
  }) async {
    final AmphitheatrePlatform platform = getAmphitheatrePlatform();

    _progressSubscription = platform.exportProgressEvents
        .listen((final AmphitheatreExportProgressEvent event) {
      final double? value = event.progress;
      if (event.id == id && value != null && !_progress.isClosed) {
        _progress.add(value.clamp(0.0, 1.0));
      }
    });

    try {
      final String tempDir = await platform.getTemporaryDirectory();
      final String outputPath =
          platform.joinPath(tempDir, 'amphitheatre_export_$id.mp4');

      // The export may be cancelled before it ever reaches the platform.
      if (_cancelRequested) {
        throw PlatformException(
          code: AmphitheatreErrorCodes.cancelled,
          message: 'The export was cancelled.',
        );
      }

      final String result = await platform.startExport(
        id: id,
        inputPath: inputPath,
        outputPath: outputPath,
        startMs: start?.inMilliseconds,
        endMs: end?.inMilliseconds,
        quality: quality,
      );

      if (!_progress.isClosed) _progress.add(1.0);
      _result.complete(result);
    } on PlatformException catch (exception) {
      _result.completeError(
        AmphitheatreExportException(
          code: exception.code,
          message: exception.message,
        ),
      );
    } on Object catch (exception) {
      _result.completeError(
        AmphitheatreExportException(
          code: AmphitheatreErrorCodes.exportFailed,
          message: exception.toString(),
        ),
      );
    } finally {
      await _progressSubscription?.cancel();
      await _progress.close();
    }
  }
}

/// Exports (trims and/or transcodes) videos using the platform's native media
/// frameworks.
///
/// The heavy lifting happens off the UI thread on the platform side and video
/// data is streamed rather than loaded into memory, so exports of arbitrarily
/// large files are safe.
///
/// Example:
///
/// ```dart
/// final session = AmphitheatreExporter.start(
///   inputPath: video.path,
///   start: const Duration(seconds: 2),
///   end: const Duration(seconds: 32),
///   quality: AmphitheatreExportQuality.fhd1080,
/// );
///
/// session.progress.listen((p) => print('${(p * 100).round()}%'));
///
/// try {
///   final outputPath = await session.result;
/// } on AmphitheatreExportException catch (e) {
///   if (!e.wasCancelled) print('Failed: ${e.code}');
/// }
/// ```
abstract final class AmphitheatreExporter {
  static int _sessionCounter = 0;

  /// Start exporting the video at [inputPath].
  ///
  /// [start] and [end] optionally trim the video to the given range. [quality]
  /// selects between a lossless passthrough remux and transcoding to a target
  /// resolution (see [AmphitheatreExportQuality]).
  ///
  /// The export begins immediately; the returned session exposes progress,
  /// the result, and cancellation.
  static AmphitheatreExportSession start({
    required final String inputPath,
    final Duration? start,
    final Duration? end,
    final AmphitheatreExportQuality quality =
        AmphitheatreExportQuality.passthrough,
  }) {
    if (start != null && end != null && end <= start) {
      throw ArgumentError.value(end, 'end', 'must be after start');
    }

    final String id =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${_sessionCounter++}';

    final AmphitheatreExportSession session = AmphitheatreExportSession._(id);
    unawaited(
      session._run(
        inputPath: inputPath,
        start: start,
        end: end,
        quality: quality,
      ),
    );
    return session;
  }
}
