import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/media.dart';

import 'fake_host.dart';

void main() {
  setUp(() => MediaHost.current = FakeMediaHost());

  testWidgets('Touch reports a tap and fades while it is held', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Touch(
            onPress: () => taps++,
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      ),
    );

    final press = await tester.startGesture(tester.getCenter(find.byType(Touch)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      .8,
    );

    await press.up();
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });

  testWidgets('the microphone banner paints with the host and reports a tap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: MicPermissionBanner(
            label: 'Tap to enable microphone',
            onTap: () => taps++,
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('Tap to enable microphone'));
    expect(label.style?.color, const Color(0xFFFFFFFF));

    await tester.tap(find.byType(MicPermissionBanner));
    await tester.pump(const Duration(milliseconds: 300));
    expect(taps, 1);
  });
}
