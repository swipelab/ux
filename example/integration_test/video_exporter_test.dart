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
      final video = await rootBundle.load(
        'integration_test/assets/twenty_seconds.mp4',
      );
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/source.mp4');
      await source.writeAsBytes(video.buffer.asUint8List());
      final out = File('${dir.path}/out.mp4');

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
      await expectLater(
        session.done.timeout(const Duration(seconds: 10)),
        throwsA(
          isA<XVideoExportException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(out.existsSync(), isFalse);
    },
  );
}
