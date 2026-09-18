import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every library reachable from [entry] through ux's own imports and exports.
Set<String> reachable(String entry) {
  final directive = RegExp(
    r'''^(?:import|export)\s+'([^']+)'[^;]*;''',
    multiLine: true,
    dotAll: true,
  );
  final seen = <String>{};
  void visit(String path) {
    if (!seen.add(path)) return;
    final source = File(path).readAsStringSync();
    for (final match in directive.allMatches(source)) {
      final uri = match.group(1)!;
      if (uri.startsWith('package:ux/')) {
        visit('lib/${uri.substring('package:ux/'.length)}');
      } else if (!uri.contains(':')) {
        visit(File(path).parent.uri.resolve(uri).toFilePath());
      }
    }
  }

  visit(entry);
  return seen;
}

void main() {
  test('ux.dart reaches no dart:ffi, dart:io or platform channel', () {
    final native = RegExp(
      r"import 'dart:(?:ffi|io)'|MethodChannel|EventChannel|BasicMessageChannel",
    );
    final offenders = [
      for (final path in reachable('lib/ux.dart'))
        if (native.hasMatch(File(path).readAsStringSync())) path,
    ];
    expect(offenders, isEmpty);
  });
}
