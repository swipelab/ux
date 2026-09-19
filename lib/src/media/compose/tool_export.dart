import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Encode [image] to a PNG temp file. Used by tool screens (crop, draw)
/// when the user applies an edit. The PNG offload to a `compute()`
/// isolate is parked behind Phase 6.
Future<io.File> writeToolExportPng(ui.Image image) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = byteData!.buffer.asUint8List();
  final tmp = await getTemporaryDirectory();
  final stamp = clock.now().microsecondsSinceEpoch;
  final out = io.File(p.join(tmp.path, 'compose_$stamp.png'));
  await out.writeAsBytes(bytes, flush: true);
  return out;
}
