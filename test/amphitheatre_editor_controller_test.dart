// Test sources are not part of the public API surface.
// ignore_for_file: public_member_api_docs

import 'package:amphitheatre/amphitheatre.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AmphitheatreEditorController', () {
    late AmphitheatreEditorController controller;

    setUp(() {
      controller = AmphitheatreEditorController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('starts empty without modifications', () {
      expect(controller.value.isEmpty, isTrue);
      expect(controller.hasModification, isFalse);
      expect(controller.canUndo, isFalse);
    });

    test('crop applies a modification', () {
      controller.crop(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );

      expect(controller.value.crop, isNotNull);
      expect(controller.value.crop!.start, Duration.zero);
      expect(controller.value.crop!.end, const Duration(seconds: 10));
    });

    test('markInitial establishes a baseline that is not a modification', () {
      controller
        ..crop(start: Duration.zero, end: const Duration(seconds: 10))
        ..markInitial();

      expect(controller.hasModification, isFalse);
      expect(controller.canUndo, isFalse);

      controller.crop(
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 9),
      );

      expect(controller.hasModification, isTrue);
    });

    test('uncommitted crops do not enter the undo history', () {
      controller
        ..crop(start: Duration.zero, end: const Duration(seconds: 10))
        ..markInitial();

      // Simulate a drag: many intermediate values, then a single commit.
      for (int i = 1; i <= 100; i++) {
        controller.crop(
          start: Duration(milliseconds: i * 10),
          end: const Duration(seconds: 10),
          commit: false,
        );
      }

      expect(controller.canUndo, isFalse);
      controller.commitPending();
      expect(controller.canUndo, isTrue);

      // The whole drag is one undo step, back to the initial value.
      controller.undo();
      expect(controller.value.crop!.start, Duration.zero);
      expect(controller.canUndo, isFalse);
    });

    test('undo walks back through committed values', () {
      controller
        ..crop(start: Duration.zero, end: const Duration(seconds: 10))
        ..markInitial()
        ..crop(start: const Duration(seconds: 1), end: const Duration(seconds: 10))
        ..crop(start: const Duration(seconds: 2), end: const Duration(seconds: 10));

      expect(controller.canUndo, isTrue);

      controller.undo();
      expect(controller.value.crop!.start, const Duration(seconds: 1));

      controller.undo();
      expect(controller.value.crop!.start, Duration.zero);
      expect(controller.canUndo, isFalse);
      expect(controller.hasModification, isFalse);
    });

    test('history is bounded', () {
      controller
        ..crop(start: Duration.zero, end: const Duration(minutes: 5))
        ..markInitial();

      for (int i = 1;
          i <= AmphitheatreEditorController.maxHistoryLength + 50;
          i++) {
        controller.crop(
          start: Duration(milliseconds: i),
          end: const Duration(minutes: 5),
        );
      }

      int undoCount = 0;
      while (controller.canUndo) {
        controller.undo();
        undoCount++;
      }

      expect(
        undoCount,
        lessThanOrEqualTo(AmphitheatreEditorController.maxHistoryLength),
      );
    });

    test('redundant crops are ignored', () {
      controller.crop(start: Duration.zero, end: const Duration(seconds: 10));

      int notifications = 0;
      controller.addListener(() => notifications++);
      controller.crop(start: Duration.zero, end: const Duration(seconds: 10));

      expect(notifications, isZero);
    });
  });

  group('AmphitheatreEditorOptions', () {
    test('shouldAutoAccept requires opt-in', () {
      const AmphitheatreEditorOptions defaults = AmphitheatreEditorOptions();
      expect(defaults.shouldAutoAccept(const Duration(seconds: 5)), isFalse);

      const AmphitheatreEditorOptions optedIn =
          AmphitheatreEditorOptions(autoAcceptShortVideos: true);
      expect(optedIn.shouldAutoAccept(const Duration(seconds: 5)), isTrue);
      expect(optedIn.shouldAutoAccept(const Duration(seconds: 30)), isFalse);
    });

    test('equality includes every option', () {
      const AmphitheatreEditorOptions a = AmphitheatreEditorOptions();
      const AmphitheatreEditorOptions b =
          AmphitheatreEditorOptions(strict: true);
      const AmphitheatreEditorOptions c = AmphitheatreEditorOptions(
        exportQuality: AmphitheatreExportQuality.hd720,
      );

      expect(a, isNot(equals(b)));
      expect(a, isNot(equals(c)));
      expect(a, equals(const AmphitheatreEditorOptions()));
    });
  });
}
