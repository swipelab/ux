@Skip('the Dart detector does not read long texts yet')
@Tags(['performance'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

const _families = [
  (
    'prose with links',
    'see https://example.com/a?b=1, mail ops@example.com or call '
        '+40 712 345 678. ',
  ),
  ("'a-' runs", 'a-'),
  ("'0 ' runs", '0 '),
  ("'1-' runs", '1-'),
  ("'%2' runs", '%2'),
  ("'a@' runs", 'a@'),
  ("'1.' runs", '1.'),
  ("'a.' runs", 'a.'),
  ("'+1 ' runs", '+1 '),
  ("'(' runs", '('),
  ("'x://' runs", 'x://'),
  ('CJK-glued domains', '访问example.com然后'),
];

String _repeat(String unit) {
  final out = StringBuffer();
  while (out.length < 160000) {
    out.write(unit);
  }
  return out.toString().substring(0, 160000);
}

void main() {
  for (final (name, unit) in _families) {
    test('a 160,000-character text of $name reads in under 2 s', () {
      final text = _repeat(unit);
      final watch = Stopwatch()..start();
      linksOf(text);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  }

  test('a 160,000-character URL reads in under 2 s', () {
    final text = 'https://example.com/${_repeat('a').substring(20)}';
    final watch = Stopwatch()..start();
    linksOf(text);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
