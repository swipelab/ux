import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _directive = RegExp(
  r'''^(?:import|export|part)\s+(['"])(.+?)\1''',
  multiLine: true,
);

/// Every ux file reachable from [entry] through imports, exports and parts,
/// and every other package those files name.
({Set<String> files, Set<String> packages}) closure(String entry) {
  final files = <String>{};
  final packages = <String>{};
  void visit(String path) {
    if (!files.add(path)) return;
    final source = File(path).readAsStringSync();
    for (final match in _directive.allMatches(source)) {
      final uri = match.group(2)!;
      if (uri.startsWith('package:ux/')) {
        visit('lib/${uri.substring('package:ux/'.length)}');
      } else if (uri.startsWith('package:')) {
        packages.add(uri.substring('package:'.length).split('/').first);
      } else if (!uri.contains(':')) {
        visit(File(path).parent.uri.resolve(uri).toFilePath());
      }
    }
  }

  visit(entry);
  return (files: files, packages: packages);
}

void main() {
  final pure = closure('lib/ux.dart');

  test('ux.dart reaches no dart:ffi, dart:io or platform channel', () {
    final native = RegExp(
      r'''(?:import|export)\s+['"]dart:(?:ffi|io)['"]'''
      r'|MethodChannel|EventChannel|BasicMessageChannel',
    );
    final offenders = [
      for (final path in pure.files)
        if (native.hasMatch(File(path).readAsStringSync())) path,
    ];
    expect(offenders, isEmpty);
  });

  test('ux.dart reaches only packages known to compile for the web', () {
    expect(pure.packages.difference({'flutter', 'clock'}), isEmpty);
  });
}
