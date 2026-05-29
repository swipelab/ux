import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/view_padding.dart';

void main() {
  testWidgets('animated viewPadding advances past _from on subsequent frames', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    final insets = XInsets.instance;

    addTearDown(tester.view.resetViewPadding);

    // Seed: snap to a known starting padding (no pending animation).
    tester.view.viewPadding = FakeViewPadding.zero;
    binding.handleMetricsChanged();
    await tester.pump();
    expect(insets.viewPadding.top, 0);

    // Arm a 200ms animation, then change the system padding.
    unawaited(insets.setSystemUiMode(
      SystemUiMode.edgeToEdge,
      animate: const Duration(milliseconds: 200),
    ));
    tester.view.viewPadding = const FakeViewPadding(top: 100);
    binding.handleMetricsChanged();

    // Drive the lerp chain across a handful of frames. Pre-fix, `_start`
    // was assigned `currentSystemFrameTimeStamp` (raw since-boot) while
    // the frame-callback `ts` is epoch-adjusted — different time domains
    // gave `dt` a massively negative value, `clamp` pinned `t = 0`, and
    // `_current` never moved past `_from`. The expectation below would
    // fail with `viewPadding.top == 0`.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(insets.viewPadding.top, greaterThan(0));

    // Drain the animation chain so no transient callback leaks past
    // teardown.
    await tester.pump(const Duration(seconds: 1));
  });
}
