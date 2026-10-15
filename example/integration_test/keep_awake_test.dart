import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/window.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final window = XWindow.instance;

  tearDown(() => window.keepAwake(false));

  testWidgets('the screen hold is taken and released', (tester) async {
    await window.keepAwake(true);

    await window.keepAwake(false);
  });

  testWidgets('holding twice takes one hold, released by one call', (
    tester,
  ) async {
    await window.keepAwake(true);
    await window.keepAwake(true);

    await window.keepAwake(false);
  });

  testWidgets('releasing a hold nobody took succeeds', (tester) async {
    await window.keepAwake(false);
  });
}
