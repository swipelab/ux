import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
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
