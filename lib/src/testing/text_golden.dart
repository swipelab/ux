import 'dart:io';

import 'package:matcher/matcher.dart';

/// Matches a [String] against the contents of a text golden file.
///
/// If the file is missing, or [update] is `true`, the matcher writes the
/// candidate to disk and succeeds. Otherwise it compares the candidate to the
/// on-disk contents byte-for-byte.
///
/// The [update] flag is left to the caller — `ux` has no opinion on how
/// regeneration is triggered. For flutter_test users, pass
/// `autoUpdateGoldenFiles` so `flutter test --update-goldens` also updates
/// text goldens:
///
/// ```dart
/// import 'package:flutter_test/flutter_test.dart';
/// import 'package:ux/testing.dart';
///
/// expect(snapshot, matchesTextGolden(path, update: autoUpdateGoldenFiles));
/// ```
///
/// Use for RPC responses, log output, formatted data — anywhere a PNG
/// comparison doesn't fit.
Matcher matchesTextGolden(String path, {bool update = false}) =>
    _TextGoldenMatcher(path, update: update);

class _TextGoldenMatcher extends Matcher {
  _TextGoldenMatcher(this.path, {required this.update});

  final String path;
  final bool update;

  @override
  bool matches(Object? item, Map<Object?, Object?> matchState) {
    if (item is! String) {
      matchState['reason'] = 'expected String, got ${item.runtimeType}';
      return false;
    }
    final file = File(path);
    if (!file.existsSync() || update) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(item);
      return true;
    }
    final expected = file.readAsStringSync();
    if (expected == item) return true;
    matchState['expected'] = expected;
    matchState['actual'] = item;
    return false;
  }

  @override
  Description describe(Description d) =>
      d.add('matches the text golden at $path');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatch,
    Map<Object?, Object?> matchState,
    bool verbose,
  ) {
    if (matchState.containsKey('reason')) {
      return mismatch.add(matchState['reason']! as String);
    }
    return mismatch
        .add('differs from golden at $path.\n')
        .add('--- expected ---\n')
        .add(matchState['expected']?.toString() ?? '')
        .add('\n--- actual ---\n')
        .add(matchState['actual']?.toString() ?? '')
        .add('\nPass `update: true` (or `autoUpdateGoldenFiles`) to regenerate.');
  }
}
