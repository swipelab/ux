import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the example iOS release executable exports dart:ffi process symbols', () {
    final xc = File('example/ios/Flutter/Release.xcconfig').readAsStringSync();
    expect(xc.contains('-Wl,-export_dynamic'), isTrue);
  });
}
