import 'package:flutter_test/flutter_test.dart';
import 'package:ux/keyboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XKeyboard.snapToPixelGrid', () {
    test('rounds to the physical pixel grid', () {
      expect(XKeyboard.snapToPixelGrid(100.4, 3), closeTo(301 / 3, 1e-9));
      expect(XKeyboard.snapToPixelGrid(336.33, 3), closeTo(1009 / 3, 1e-9));
      expect(XKeyboard.snapToPixelGrid(100.4, 1), 100.0);
      expect(XKeyboard.snapToPixelGrid(100.4, 0), 100.4);
    });
  });

  group('XKeyboard publishing at 3x', () {
    test('a native step within one physical pixel does not notify', () {
      var native = 100.0;
      final kb =
          XKeyboard.test(nativeHeight: () => native, devicePixelRatio: 3);
      var notified = 0;
      kb.addListener(() => notified++);
      kb.debugFrame(const Duration(milliseconds: 16));
      expect(kb.height, 100.0);
      expect(notified, 1);
      native = 100.1;
      kb.debugFrame(const Duration(milliseconds: 32));
      expect(kb.height, 100.0);
      expect(notified, 1);
    });

    test('a 0.4pt native step publishes its physical pixel', () {
      var native = 100.0;
      final kb =
          XKeyboard.test(nativeHeight: () => native, devicePixelRatio: 3);
      var notified = 0;
      kb.addListener(() => notified++);
      kb.debugFrame(const Duration(milliseconds: 16));
      native = 100.4;
      kb.debugFrame(const Duration(milliseconds: 32));
      expect(kb.height, closeTo(301 / 3, 1e-9));
      expect(notified, 2);
    });

    test('a 0.6pt native step lands on the pixel grid', () {
      var native = 100.0;
      final kb =
          XKeyboard.test(nativeHeight: () => native, devicePixelRatio: 3);
      kb.debugFrame(const Duration(milliseconds: 16));
      native = 100.6;
      kb.debugFrame(const Duration(milliseconds: 32));
      expect(kb.height, closeTo(302 / 3, 1e-9));
    });

    test('a creeping native reading publishes whole physical pixel steps', () {
      var native = 100.0;
      final kb =
          XKeyboard.test(nativeHeight: () => native, devicePixelRatio: 3);
      final published = <double>[];
      kb.addListener(() => published.add(kb.height));
      var t = 0;
      for (var v = 100.0; v <= 100.71; v += 0.1) {
        native = v;
        kb.debugFrame(Duration(milliseconds: t += 16));
      }
      expect(published.first, 100.0);
      expect(published.last, closeTo(302 / 3, 1e-9));
      for (var i = 1; i < published.length; i++) {
        final px = (published[i] - published[i - 1]) * 3;
        expect(px, closeTo(px.roundToDouble(), 1e-6));
        expect(px.abs(), greaterThan(1 - 1e-6));
      }
    });

    test('a rise settles on the curve target, not the native excess', () {
      var gen = 0;
      var tracking = 0;
      final kb = XKeyboard.test(
        nativeHeight: () => 336.33,
        isTracking: () => tracking,
        animTarget: () => 336.0,
        animDuration: () => 0.25,
        animGen: () => gen,
        devicePixelRatio: 3,
      );
      var notified = 0;
      kb.addListener(() => notified++);
      gen = 1;
      // The generation lands at 16ms, so the 256ms frame is the first with
      // curve t >= 1 — the settle frame under test.
      for (var t = 16; t <= 256; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, closeTo(336.0, 1e-9));
      final settled = notified;
      tracking = 1;
      kb.debugFrame(const Duration(milliseconds: 272));
      expect(kb.height, closeTo(336.0, 1e-9));
      expect(notified, settled);
    });

    test('a native IME resize after settle is not capped at the old target', () {
      var gen = 0;
      var native = 336.33;
      final kb = XKeyboard.test(
        nativeHeight: () => native,
        animTarget: () => 336.0,
        animDuration: () => 0.25,
        animGen: () => gen,
        devicePixelRatio: 3,
      );
      gen = 1;
      for (var t = 16; t <= 256; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, closeTo(336.0, 1e-9));
      native = 420.0;
      kb.debugFrame(const Duration(milliseconds: 272));
      expect(kb.height, 420.0);
    });

    test('a duration-0 re-announce of the settled target stays on it', () {
      var gen = 0;
      var duration = 0.25;
      final kb = XKeyboard.test(
        nativeHeight: () => 336.33,
        animTarget: () => 336.0,
        animDuration: () => duration,
        animGen: () => gen,
        devicePixelRatio: 3,
      );
      gen = 1;
      for (var t = 16; t <= 256; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, closeTo(336.0, 1e-9));
      duration = 0;
      gen = 2;
      kb.debugFrame(const Duration(milliseconds: 272));
      expect(kb.height, closeTo(336.0, 1e-9));
      kb.debugFrame(const Duration(milliseconds: 288));
      expect(kb.height, closeTo(336.0, 1e-9));
    });

    test('a same-height curve re-announce settles on the curve target', () {
      var gen = 0;
      final kb = XKeyboard.test(
        nativeHeight: () => 336.33,
        animTarget: () => 336.0,
        animDuration: () => 0.25,
        animGen: () => gen,
        devicePixelRatio: 3,
      );
      gen = 1;
      for (var t = 16; t <= 256; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, closeTo(336.0, 1e-9));
      var notified = 0;
      kb.addListener(() => notified++);
      gen = 2;
      for (var t = 272; t <= 528; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, closeTo(336.0, 1e-9));
      expect(notified, 0);
    });

    test('a close settles on the lagging native reading', () {
      var gen = 0;
      var native = 336.33;
      var target = 336.0;
      final kb = XKeyboard.test(
        nativeHeight: () => native,
        animTarget: () => target,
        animDuration: () => 0.25,
        animGen: () => gen,
        devicePixelRatio: 3,
      );
      gen = 1;
      for (var t = 16; t <= 256; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, closeTo(336.0, 1e-9));
      gen = 2;
      target = 0;
      native = 48.0;
      for (var t = 272; t <= 528; t += 16) {
        kb.debugFrame(Duration(milliseconds: t));
      }
      expect(kb.height, 48.0);
    });

    test('the rest reading and the tracking base collapse to one pixel', () {
      // The native tracking base is sampled from the same reader as the
      // rest reading; snapping makes offset 0 publish nothing.
      var native = 336.33;
      var tracking = 0;
      final kb = XKeyboard.test(
        nativeHeight: () => native,
        isTracking: () => tracking,
        devicePixelRatio: 3,
      );
      final published = <double>[];
      kb.addListener(() => published.add(kb.height));
      kb.debugFrame(const Duration(milliseconds: 16));
      tracking = 1;
      native = 1009 / 3;
      kb.debugFrame(const Duration(milliseconds: 32));
      expect(published, [closeTo(1009 / 3, 1e-9)]);
    });
  });

  group('XKeyboard.clampPrediction', () {
    test('a rise never overshoots the native reading', () {
      expect(
        XKeyboard.clampPrediction(
            h: 120, native: 100, animFrom: 0, animTo: 336, current: 110),
        100,
      );
      expect(
        XKeyboard.clampPrediction(
            h: 90, native: 100, animFrom: 0, animTo: 336, current: 95),
        90,
      );
    });

    test('a close holds the height at a lagging native reading', () {
      expect(
        XKeyboard.clampPrediction(
            h: 45, native: 60, animFrom: 200, animTo: 0, current: 62),
        60,
      );
    });

    test('a close keeps the prediction when native runs ahead of it', () {
      expect(
        XKeyboard.clampPrediction(
            h: 45, native: 30, animFrom: 200, animTo: 0, current: 50),
        45,
      );
    });

    test('a native flash to full mid-close cannot raise the height', () {
      expect(
        XKeyboard.clampPrediction(
            h: 45, native: 336, animFrom: 200, animTo: 0, current: 50),
        50,
      );
    });

    test('a flash on the first close frame keeps the dragged height', () {
      expect(
        XKeyboard.clampPrediction(
            h: 199, native: 336, animFrom: 200, animTo: 0, current: 200),
        200,
      );
    });
  });
}
