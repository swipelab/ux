// Runs inside an oracle commit's archive as test/oracle/replay_test.dart: its
// XUrl.match over each text, with XUrl.debugDetect answering the probe's
// recorded buffer.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/url.dart';

import 'wire.dart';

const _dir = String.fromEnvironment('UX_ORACLE_DIR');

void main() {
  test('XUrl.match replays the probe readings', () {
    final texts = File('$_dir/texts')
        .readAsLinesSync()
        .map(fromUtf16Base64)
        .toList();
    final probes = File('$_dir/probe')
        .readAsLinesSync()
        .map(ProbeReading.fromLine)
        .toList();
    expect(probes.length, texts.length);
    var buffer = Uint8List(0);
    XUrl.debugDetect = (_) => buffer;
    final out = StringBuffer();
    for (var i = 0; i < texts.length; i++) {
      buffer = probes[i].buffer;
      out.writeln(
        asciiJson([
          for (final m in XUrl.match(texts[i]))
            [m.start, m.end, m.kind.name, m.url],
        ]),
      );
    }
    File('$_dir/match').writeAsStringSync(out.toString());
  });
}
