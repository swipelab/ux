import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a re-encoding export with audio cancelled midway fails with cancelled '
    'and leaves no file',
    (tester) async {
      final (source, out) = await _twentySeconds();

      final session = XVideoExporter.start(
        XVideoExportRequest(
          path: source.path,
          outPath: out.path,
          transform: const [30, 0, 0, 0, 30, 0, 0, 0, 1],
          outWidth: 1920,
          outHeight: 1080,
          videoBitrate: 6600000,
        ),
      );
      await session.progress.firstWhere((value) => value > 0.25);
      await session.cancel();
      await expectLater(session.done.timeout(_cancelTimeout), _failsCancelled);
      expect(out.existsSync(), isFalse);
    },
  );

  testWidgets(
    'a pass-through export cancelled as it starts fails with cancelled and '
    'leaves no file',
    (tester) async {
      final (source, out) = await _twentySeconds();

      final session = XVideoExporter.start(
        XVideoExportRequest(path: source.path, outPath: out.path),
      );
      await session.cancel();
      await expectLater(session.done.timeout(_cancelTimeout), _failsCancelled);
      expect(out.existsSync(), isFalse);
    },
  );

  testWidgets(
    'a re-encoding export cancelled as it starts fails with cancelled and '
    'leaves no file',
    (tester) async {
      final (source, out) = await _twentySeconds();

      final session = XVideoExporter.start(
        XVideoExportRequest(
          path: source.path,
          outPath: out.path,
          transform: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
          outWidth: 64,
          outHeight: 36,
        ),
      );
      await session.cancel();
      await expectLater(session.done.timeout(_cancelTimeout), _failsCancelled);
      expect(out.existsSync(), isFalse);
    },
  );
}

const _cancelTimeout = Duration(seconds: 10);

final _failsCancelled = throwsA(
  isA<XVideoExportException>().having((e) => e.code, 'code', 'cancelled'),
);

/// twenty_seconds.mp4 in a fresh temporary directory, and the path an export
/// of it writes to there.
Future<(File, File)> _twentySeconds() async {
  final video = await rootBundle.load(
    'integration_test/assets/twenty_seconds.mp4',
  );
  final dir = await Directory.systemTemp.createTemp();
  addTearDown(() => dir.delete(recursive: true));
  final source = File('${dir.path}/source.mp4');
  await source.writeAsBytes(video.buffer.asUint8List());
  return (source, File('${dir.path}/out.mp4'));
}
