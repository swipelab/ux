import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("a listen gets the OS's Reduce Motion", (tester) async {
    final event = await const EventChannel('ux/accessibility/events')
        .receiveBroadcastStream()
        .first;
    debugPrint('reduceMotion: ${(event as Map)['reduced']}');
    expect(event, {'type': 'reduceMotion', 'reduced': isA<bool>()});
  }, skip: defaultTargetPlatform != TargetPlatform.macOS);
}
