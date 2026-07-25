// Test sources are not part of the public API surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:amphitheatre/amphitheatre.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake platform that lets tests drive export completion, failure, and
/// progress events.
final class _FakeAmphitheatrePlatform extends AmphitheatrePlatform {
  final StreamController<AmphitheatreExportProgressEvent> events =
      StreamController.broadcast();

  final List<String> cancelledIds = [];
  Map<String, Object?>? lastStartArguments;
  Completer<String>? pendingExport;

  @override
  String get pathSeparator => '/';

  @override
  Future<String> getTemporaryDirectory() async => '/tmp/amphitheatre';

  @override
  Future<String> startExport({
    required final String id,
    required final String inputPath,
    required final String outputPath,
    required final int? startMs,
    required final int? endMs,
    required final AmphitheatreExportQuality quality,
  }) {
    lastStartArguments = {
      'id': id,
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'endMs': endMs,
      'quality': quality,
    };
    pendingExport = Completer<String>();
    return pendingExport!.future;
  }

  @override
  Future<bool> cancelExport(final String id) async {
    cancelledIds.add(id);
    pendingExport?.completeError(
      PlatformException(
        code: AmphitheatreErrorCodes.cancelled,
        message: 'The export was cancelled.',
      ),
    );
    return true;
  }

  @override
  Stream<AmphitheatreExportProgressEvent> get exportProgressEvents =>
      events.stream;

  Future<void> dispose() => events.close();
}

void main() {
  late _FakeAmphitheatrePlatform platform;

  setUp(() {
    platform = _FakeAmphitheatrePlatform();
    setAmphitheatrePlatform(platform);
  });

  tearDown(() async {
    setAmphitheatrePlatform(null);
    await platform.dispose();
  });

  group('AmphitheatreExporter', () {
    test('rejects an invalid trim range', () {
      expect(
        () => AmphitheatreExporter.start(
          inputPath: '/videos/in.mp4',
          start: const Duration(seconds: 10),
          end: const Duration(seconds: 5),
        ),
        throwsArgumentError,
      );
    });

    test('passes trim and quality through to the platform', () async {
      AmphitheatreExporter.start(
        inputPath: '/videos/in.mp4',
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 30),
        quality: AmphitheatreExportQuality.fhd1080,
      );
      await pumpEventQueue();

      final Map<String, Object?> arguments = platform.lastStartArguments!;
      expect(arguments['inputPath'], '/videos/in.mp4');
      expect(arguments['startMs'], 1000);
      expect(arguments['endMs'], 30000);
      expect(arguments['quality'], AmphitheatreExportQuality.fhd1080);
      expect(
        arguments['outputPath'],
        allOf(startsWith('/tmp/amphitheatre/'), endsWith('.mp4')),
      );
    });

    test('completes with the output path and final progress', () async {
      final AmphitheatreExportSession session = AmphitheatreExporter.start(
        inputPath: '/videos/in.mp4',
      );

      final List<double> progress = [];
      session.progress.listen(progress.add);
      await pumpEventQueue();

      final String id = platform.lastStartArguments!['id']! as String;
      platform.events
        ..add(AmphitheatreExportProgressEvent(id: id, progress: 0.25))
        // Events for other exports must be ignored.
        ..add(const AmphitheatreExportProgressEvent(id: 'other', progress: 0.9))
        ..add(AmphitheatreExportProgressEvent(id: id, progress: 0.5));
      await pumpEventQueue();

      platform.pendingExport!.complete('/tmp/amphitheatre/out.mp4');

      expect(await session.result, '/tmp/amphitheatre/out.mp4');
      expect(session.isComplete, isTrue);
      await pumpEventQueue();
      expect(progress, [0.25, 0.5, 1.0]);
    });

    test('surfaces platform failures as typed exceptions', () async {
      final AmphitheatreExportSession session = AmphitheatreExporter.start(
        inputPath: '/videos/in.mp4',
      );
      await pumpEventQueue();

      platform.pendingExport!.completeError(
        PlatformException(
          code: AmphitheatreErrorCodes.exportFailed,
          message: 'Encoder died.',
        ),
      );

      await expectLater(
        session.result,
        throwsA(
          isA<AmphitheatreExportException>()
              .having((final e) => e.code, 'code',
                  AmphitheatreErrorCodes.exportFailed)
              .having((final e) => e.message, 'message', 'Encoder died.')
              .having((final e) => e.wasCancelled, 'wasCancelled', isFalse),
        ),
      );
    });

    test('cancel aborts the export and marks the error as cancellation',
        () async {
      final AmphitheatreExportSession session = AmphitheatreExporter.start(
        inputPath: '/videos/in.mp4',
      );
      await pumpEventQueue();

      await session.cancel();

      await expectLater(
        session.result,
        throwsA(
          isA<AmphitheatreExportException>()
              .having((final e) => e.wasCancelled, 'wasCancelled', isTrue),
        ),
      );
      expect(platform.cancelledIds, [session.id]);
    });
  });
}
