import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the example iOS release executable exports dart:ffi process symbols', () {
    final xc = File('example/ios/Flutter/Release.xcconfig').readAsStringSync();
    expect(xc.contains('EXPORTED_SYMBOLS_FILE'), isTrue);
    final exp = File('example/ios/Runner/process_ffi.exp').readAsStringSync();
    expect(exp.contains('_ux_enable_interactive_dismiss'), isTrue);
  });
}
