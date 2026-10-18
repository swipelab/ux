// Times detectLinks over adversarial texts of 40,000 and 160,000 characters:
// 3 warm-up runs, then the median of 9.
//
//   dart compile exe tool/url_bench.dart -o build/url_bench && build/url_bench
import 'dart:io';

import 'package:ux/src/url/detect.dart';

/// Each family: its name, the text before the repeated unit, and the unit.
const _families = [
  ("'x://' runs", '', 'x://'),
  ("'a-' runs after https://", 'https://', 'a-'),
  ("'a.' runs after https://", 'https://', 'a.'),
  ("'%2' runs after https://", 'https://', '%2'),
  ("'(' runs after https://", 'https://', '('),
  ("'(' runs in a path", 'https://example.com/', '('),
  ('a URL', 'https://example.com/', 'a'),
  ("userinfo with no '@'", 'https://', 'a:'),
  ("'a@' runs after https://", 'https://', 'a@'),
  ("'a-' runs", '', 'a-'),
  ("'a.' runs", '', 'a.'),
  ("'%2' runs", '', '%2'),
  ("'(' runs", '', '('),
  ("'a@' runs", '', 'a@'),
];

const _sizes = [40000, 160000];

String _text(String prefix, String unit, int length) {
  final out = StringBuffer(prefix);
  while (out.length < length) {
    out.write(unit);
  }
  return out.toString().substring(0, length);
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

void main() {
  var ok = true;
  stdout.writeln(
    '${'family'.padRight(32)} ${'40k ms'.padLeft(8)} '
    '${'160k ms'.padLeft(8)} ${'ratio'.padLeft(6)}',
  );
  for (final (name, prefix, unit) in _families) {
    final medians = <double>[];
    for (final size in _sizes) {
      final text = _text(prefix, unit, size);
      for (var i = 0; i < 3; i++) {
        detectLinks(text);
      }
      final times = <double>[];
      for (var i = 0; i < 9; i++) {
        final watch = Stopwatch()..start();
        detectLinks(text);
        times.add(watch.elapsedMicroseconds / 1000);
      }
      medians.add(_median(times));
    }
    final ratio = medians[1] / medians[0];
    final pass = medians[1] <= 100 && ratio <= 5;
    ok = ok && pass;
    stdout.writeln(
      '${name.padRight(32)} ${medians[0].toStringAsFixed(2).padLeft(8)} '
      '${medians[1].toStringAsFixed(2).padLeft(8)} '
      '${ratio.toStringAsFixed(2).padLeft(6)}${pass ? '' : '  FAIL'}',
    );
  }
  exit(ok ? 0 : 1);
}
