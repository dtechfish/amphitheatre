import 'dart:async';

import 'package:amphitheatre/amphitheatre.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The quality to export a video with.
///
/// [passthrough] copies the compressed samples directly (no re-encode), which
/// is fast and lossless but does not reduce the bitrate of the video. The
/// other options transcode the video to H.264/AAC, scaling it down to the
/// named resolution (the video is never upscaled).
enum AmphitheatreExportQuality {
  /// Copy the source streams without re-encoding. Fast and lossless.
  passthrough('passthrough'),

  /// Transcode, scaling down to at most 2160p (4K UHD).
  uhd2160('2160p'),

  /// Transcode, scaling down to at most 1080p (Full HD).
  fhd1080('1080p'),

  /// Transcode, scaling down to at most 720p (HD).
  hd720('720p');

  /// The identifier for this quality on the platform channel.
  final String wireName;

  const AmphitheatreExportQuality(this.wireName);
}

/// A progress update for an export operation, keyed by the export [id].
@immutable
final class AmphitheatreExportProgressEvent {
  /// The unique identifier of the export this event belongs to.
  final String id;

  /// The progress of the export, from `0.0` to `1.0`, or null if the platform
  /// cannot determine progress for this export (e.g., during a passthrough
  /// remux on some devices).
  final double? progress;

  /// Construct an [AmphitheatreExportProgressEvent].
  const AmphitheatreExportProgressEvent({
    required this.id,
    required this.progress,
  });
}

/// Set the platform interface implementation for [Amphitheatre] and
/// [AmphitheatreEditor].
///
/// If the specified [platform] is null, the default platform implementation
/// (which uses Flutter's [MethodChannel] API) is restored.
///
/// The primary purpose of the platform interface is to make use of
/// OS/environment-provided multimedia capabilities.
void setAmphitheatrePlatform(final AmphitheatrePlatform? platform) {
  final AmphitheatrePlatform instance =
      platform ?? AmphitheatrePlatformMethodChannel();

  PlatformInterface.verify(instance, AmphitheatrePlatform._token);
  AmphitheatrePlatform._instance = instance;
}

/// Returns the currently active [AmphitheatrePlatform] instance.
///
/// For internal use within [Amphitheatre] and [AmphitheatreEditor] only.
AmphitheatrePlatform getAmphitheatrePlatform() =>
    AmphitheatrePlatform._instance;

/// The platform interface for [Amphitheatre] and [AmphitheatreEditor].
///
/// The primary purpose of the platform interface is to make use of
/// OS/environment-provided multimedia capabilities.
///
/// All file APIs deal exclusively in paths: video data is never loaded into
/// memory on the Dart side, and the platform implementations must stream data
/// rather than buffering entire files. Implementations must never delete or
/// modify the input file of an export.
abstract class AmphitheatrePlatform extends PlatformInterface {
  /// Base constructor for [AmphitheatrePlatform].
  AmphitheatrePlatform() : super(token: _token);

  /// A non-fungible token used to verify inheritance from this base class.
  static final Object _token = Object();

  static AmphitheatrePlatform _instance = AmphitheatrePlatformMethodChannel();

  // ---------------------------------------------------------------------------

  /// The character used to separate a path on the current platform.
  String get pathSeparator;

  /// Joins two path segments together.
  String joinPath(final String base, final String next) =>
      '$base$pathSeparator$next';

  /// Splits a path into its constituent segments.
  List<String> splitPath(final String path) => path.split(pathSeparator);

  /// Returns the path to a package-specific temporary directory that can be
  /// used for storing videos that are being processed.
  Future<String> getTemporaryDirectory() => throw UnimplementedError();

  /// Start exporting the video at [inputPath] to [outputPath].
  ///
  /// The video is trimmed to the range `[startMs, endMs]` (either bound may be
  /// null to keep that side of the video) and processed according to
  /// [quality].
  ///
  /// The returned future completes with the output path once the export has
  /// finished. Progress updates for the given [id] are delivered on
  /// [exportProgressEvents] while the export runs.
  ///
  /// The input file is never modified or deleted.
  ///
  /// Errors surface as [PlatformException]s with one of the
  /// `AmphitheatreErrorCodes` codes.
  Future<String> startExport({
    required final String id,
    required final String inputPath,
    required final String outputPath,
    required final int? startMs,
    required final int? endMs,
    required final AmphitheatreExportQuality quality,
  }) =>
      throw UnimplementedError();

  /// Cancel the export with the given [id].
  ///
  /// Returns true if there was an active export to cancel. The corresponding
  /// [startExport] future completes with an [AmphitheatreErrorCodes.cancelled]
  /// error.
  Future<bool> cancelExport(final String id) => throw UnimplementedError();

  /// Generates [count] evenly spaced thumbnails for the video at [path], each
  /// scaled (preserving aspect ratio) to be at most [maxHeight] pixels tall.
  ///
  /// The thumbnails are returned as encoded JPEG bytes. Implementations may
  /// return fewer than [count] images if some frames cannot be decoded.
  Future<List<Uint8List>> getThumbnails({
    required final String path,
    required final int count,
    required final int maxHeight,
  }) =>
      throw UnimplementedError();

  /// A broadcast stream of progress events for all running exports.
  Stream<AmphitheatreExportProgressEvent> get exportProgressEvents =>
      throw UnimplementedError();
}

/// The error codes that platform implementations report via
/// [PlatformException.code].
abstract final class AmphitheatreErrorCodes {
  /// The arguments supplied to the platform method were invalid.
  static const String badParams = 'ERR_BAD_PARAMS';

  /// The input file could not be found.
  static const String notFound = 'ERR_NOT_FOUND';

  /// The export was cancelled with [AmphitheatrePlatform.cancelExport].
  static const String cancelled = 'ERR_CANCELLED';

  /// The export failed. The [PlatformException.message] carries the
  /// underlying platform error description.
  static const String exportFailed = 'ERR_EXPORT_FAILED';

  /// The platform failed to provide a suitable directory or codec.
  static const String initFailed = 'ERR_INIT_FAIL';
}

/// The default implementation of [AmphitheatrePlatform], using Flutter's
/// [MethodChannel] API.
final class AmphitheatrePlatformMethodChannel extends AmphitheatrePlatform {
  static const MethodChannel _channel =
      MethodChannel('xyz.apollosoftware.amphitheatre');

  static const EventChannel _eventChannel =
      EventChannel('xyz.apollosoftware.amphitheatre/events');

  Stream<AmphitheatreExportProgressEvent>? _events;

  @override
  String get pathSeparator {
    if ([
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.fuchsia,
    ].contains(defaultTargetPlatform)) {
      return '/';
    }

    if (defaultTargetPlatform == TargetPlatform.windows) return r'\';
    throw UnsupportedError('Unsupported platform: $defaultTargetPlatform');
  }

  @override
  Future<String> getTemporaryDirectory() async =>
      (await _channel.invokeMethod<String>('getTemporaryDirectory'))!;

  @override
  Future<String> startExport({
    required final String id,
    required final String inputPath,
    required final String outputPath,
    required final int? startMs,
    required final int? endMs,
    required final AmphitheatreExportQuality quality,
  }) async =>
      (await _channel.invokeMethod<String>('startExport', <String, dynamic>{
        'id': id,
        'inputPath': inputPath,
        'outputPath': outputPath,
        'startMs': startMs,
        'endMs': endMs,
        'quality': quality.wireName,
      }))!;

  @override
  Future<bool> cancelExport(final String id) async =>
      await _channel.invokeMethod<bool>('cancelExport', <String, dynamic>{
        'id': id,
      }) ??
      false;

  @override
  Future<List<Uint8List>> getThumbnails({
    required final String path,
    required final int count,
    required final int maxHeight,
  }) async {
    final List<Object?>? thumbnails = await _channel
        .invokeMethod<List<Object?>>('getThumbnails', <String, dynamic>{
      'path': path,
      'count': count,
      'maxHeight': maxHeight,
    });

    return (thumbnails ?? const <Object?>[]).whereType<Uint8List>().toList();
  }

  @override
  Stream<AmphitheatreExportProgressEvent> get exportProgressEvents =>
      _events ??= _eventChannel
          .receiveBroadcastStream()
          .map<AmphitheatreExportProgressEvent>((final dynamic event) {
        final Map<Object?, Object?> map = event as Map<Object?, Object?>;
        return AmphitheatreExportProgressEvent(
          id: map['id']! as String,
          progress: (map['progress'] as num?)?.toDouble(),
        );
      });
}
