import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the example iOS release executable exports dart:ffi process symbols', () {
    final xc = File('example/ios/Flutter/Release.xcconfig').readAsStringSync();
    expect(xc.contains('STRIP_STYLE = non-global'), isTrue);
  });

  test('Swift entry points marked @_used compile under SymbolLinkageMarkers', () {
    final marked = Directory('darwin/ux/Sources/ux')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.swift'))
        .where((f) => f.readAsStringSync().contains('@_used'))
        .map((f) => f.path)
        .toList();
    final manifest = File('darwin/ux/Package.swift').readAsStringSync();
    expect(
      marked.isEmpty ||
          manifest.contains('.enableExperimentalFeature("SymbolLinkageMarkers")'),
      isTrue,
      reason: '@_used in ${marked.join(', ')} needs SymbolLinkageMarkers',
    );
  });
}
