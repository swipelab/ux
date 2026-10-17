// test/url/links.dart inside an oracle commit's archive. With
// UX_ORACLE_MODE=collect, expectLinks records each text; otherwise it checks
// `apple ?? expected` against that commit's XUrl.match, whose
// XUrl.debugDetect answers the probe's buffer for the text.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/url.dart';

import '../oracle/wire.dart';

/// A web link over [start, end) opening [url].
UrlMatch web(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.web);

/// An email link over [start, end) opening [url].
UrlMatch email(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.email);

/// A phone link over [start, end) opening [url].
UrlMatch phone(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.phone);

const _mode = String.fromEnvironment('UX_ORACLE_MODE');
const _dir = String.fromEnvironment('UX_ORACLE_DIR');

final Map<String, Uint8List> _buffers = {
  for (final line in File('$_dir/readings').readAsLinesSync())
    fromUtf16Base64(
      line.substring(0, line.indexOf(' ')),
    ): ProbeReading.fromLine(line.substring(line.indexOf(' ') + 1))
        .buffer,
};

/// Expects the darwin reading of [text] to be [apple], or [expected] where
/// the catalog gives no [apple].
void expectLinks(
  String text,
  List<UrlMatch> expected, {
  List<UrlMatch>? apple,
}) {
  if (_mode == 'collect') {
    File('$_dir/collect/$pid').writeAsStringSync(
      '${toUtf16Base64(text)}\n',
      mode: FileMode.append,
      flush: true,
    );
    return;
  }
  final buffer = _buffers[text];
  expect(buffer, isNotNull, reason: 'the probe read ${printable(text)}');
  XUrl.debugDetect = (_) => buffer!;
  expect(XUrl.match(text), apple ?? expected);
}
