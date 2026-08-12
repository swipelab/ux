import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/ux.dart';
import 'package:ux_example/screen_sources_page.dart';

class _RecordedList {
  _RecordedList({
    required this.allowedDisplayIds,
    required this.allowedWindowIds,
    required this.sources,
    required this.elapsed,
  });

  final Set<String> allowedDisplayIds;
  final Set<String> allowedWindowIds;
  final List<XScreenSource> sources;
  final Duration elapsed;
}

class _RecordingBackend implements XScreenSourcesBackend {
  _RecordingBackend(this.inner);

  final XScreenSourcesBackend inner;
  final List<_RecordedList> calls = [];

  @override
  XScreenCaptureMode? get captureMode => inner.captureMode;

  @override
  bool get supported => inner.supported;

  @override
  Future<bool> available() => inner.available();

  @override
  Future<bool> hasPermission() => inner.hasPermission();

  @override
  Future<bool> requestPermission() => inner.requestPermission();

  @override
  Future<List<XScreenSource>> list({
    required Set<String> allowedDisplayIds,
    required Set<String> allowedWindowIds,
    int thumbnailWidth = 320,
    int thumbnailHeight = 180,
  }) async {
    final elapsed = Stopwatch()..start();
    final sources = await inner.list(
      allowedDisplayIds: allowedDisplayIds,
      allowedWindowIds: allowedWindowIds,
      thumbnailWidth: thumbnailWidth,
      thumbnailHeight: thumbnailHeight,
    );
    elapsed.stop();
    calls.add(_RecordedList(
      allowedDisplayIds: allowedDisplayIds,
      allowedWindowIds: allowedWindowIds,
      sources: sources,
      elapsed: elapsed.elapsed,
    ));
    return sources;
  }
}

typedef _Pair = ({XScreenSourceKind kind, String id});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const ownApplication = 'ux_example';
  const firstFrameBudget = Duration(seconds: 3);

  _Pair pairOf(XScreenSource source) => (kind: source.kind, id: source.id);

  Set<_Pair> primedPairs(List<DesktopCapturerSource> primed) => {
        for (final source in primed)
          (
            kind: source.type == SourceType.Screen
                ? XScreenSourceKind.display
                : XScreenSourceKind.window,
            id: source.id,
          ),
      };

  Future<bool> pumpUntil(
    WidgetTester tester,
    bool Function() ready,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) return ready();
      await tester.pump(const Duration(milliseconds: 100));
    }
    return true;
  }

  testWidgets('the picker enumerates and captures this host', (tester) async {
    final Directory evidenceDir;
    final File evidenceFile;
    try {
      evidenceDir = Directory.systemTemp.createTempSync('ux-screen-sources-');
      evidenceFile = File('${evidenceDir.path}/screen-sources-evidence.json')
        ..writeAsStringSync('{}');
    } catch (e) {
      throw StateError(
        'evidence directory not writable: ${Directory.systemTemp.path}: $e',
      );
    }

    final evidence = <String, Object?>{'directory': evidenceDir.path};
    addTearDown(() {
      final document = const JsonEncoder.withIndent('  ').convert(evidence);
      evidenceFile.writeAsStringSync(document);
      debugPrintSynchronously('screen-sources evidence: ${evidenceFile.path}');
      debugPrintSynchronously(document);
    });

    final backend = _RecordingBackend(MethodChannelXScreenSourcesBackend());
    final primings = <List<DesktopCapturerSource>>[];
    XScreenSourcesBackend.instance = backend;
    ScreenSourcesPage.primeSources = () async {
      final primed = await ScreenSourcesPage.captureStackSources();
      primings.add(primed);
      return primed;
    };
    addTearDown(() {
      XScreenSourcesBackend.instance = MethodChannelXScreenSourcesBackend();
      ScreenSourcesPage.primeSources = ScreenSourcesPage.captureStackSources;
    });

    final available = await backend.available();
    final permission = await backend.hasPermission();
    evidence['permission'] = {
      'available': available,
      'hasPermission': permission,
    };
    expect(available, isTrue, reason: 'this host cannot serve a snapshot');
    if (!permission) {
      await backend.requestPermission();
      fail(
        'Screen Recording is not granted to ux_example.\n'
        'Grant it in System Settings › Privacy & Security › Screen & System '
        'Audio Recording by enabling ux_example (the dialog this run raised '
        'points there), then re-run:\n'
        '  (cd example && flutter test integration_test/ -d macos)\n'
        'The grant becomes visible to the app on its next launch, which the '
        're-run provides.',
      );
    }

    await tester.pumpWidget(const MaterialApp(home: ScreenSourcesPage()));
    await pumpUntil(
      tester,
      () => find.text('Refresh').evaluate().isNotEmpty,
      const Duration(seconds: 10),
    );
    expect(find.text('Refresh'), findsOneWidget);

    Future<void> refresh() async {
      final before = backend.calls.length;
      await tester.tap(find.text('Refresh'));
      final listed = await pumpUntil(
        tester,
        () => backend.calls.length > before,
        const Duration(seconds: 30),
      );
      expect(listed, isTrue, reason: 'the snapshot never came back');
    }

    await refresh();

    var retries = 0;
    var call = backend.calls.last;
    var expected = primedPairs(primings.last);
    var missing = expected.difference(call.sources.map(pairOf).toSet());
    if (missing.isNotEmpty) {
      retries = 1;
      await refresh();
      call = backend.calls.last;
      expected = primedPairs(primings.last);
      missing = expected.difference(call.sources.map(pairOf).toSet());
    }

    final snapshot = call.sources;
    final vanished = <_Pair>[];
    if (missing.isNotEmpty) {
      final fresh = primedPairs(await ScreenSourcesPage.captureStackSources());
      vanished.addAll(missing.where((pair) => !fresh.contains(pair)));
      final present = missing.where(fresh.contains).toList();
      evidence['parityMisses'] = [
        for (final pair in present) '${pair.kind.name}:${pair.id}',
      ];
      expect(
        present,
        isEmpty,
        reason: 'primed sources the snapshot never carried',
      );
    }

    evidence['parity'] = {
      'allowedDisplayIds': call.allowedDisplayIds.length,
      'allowedWindowIds': call.allowedWindowIds.length,
      'snapshotCount': snapshot.length,
      'retries': retries,
      'vanished': [for (final pair in vanished) '${pair.kind.name}:${pair.id}'],
    };
    expect(
      snapshot.length + vanished.length,
      call.allowedDisplayIds.length + call.allowedWindowIds.length,
    );

    final decoded = <String, Object?>{};
    for (final source in snapshot) {
      final thumbnail = source.thumbnailPng;
      if (thumbnail == null) continue;
      final name = '${source.kind.name}-${source.id}.png';
      File('${evidenceDir.path}/$name').writeAsBytesSync(thumbnail);
      final image = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(thumbnail);
        final frame = await codec.getNextFrame();
        return frame.image;
      });
      expect(image, isNotNull, reason: '$name does not decode');
      decoded[name] = '${image!.width}x${image.height}';
      image.dispose();
    }

    evidence['sources'] = [
      for (final source in snapshot)
        {
          'kind': source.kind.name,
          'id': source.id,
          'title': source.title,
          'applicationName': source.applicationName,
          'sourceWidth': source.sourceWidth,
          'sourceHeight': source.sourceHeight,
          'thumbnail': decoded['${source.kind.name}-${source.id}.png'],
        },
    ];

    final displays =
        snapshot.where((s) => s.kind == XScreenSourceKind.display).toList();
    final windows =
        snapshot.where((s) => s.kind == XScreenSourceKind.window).toList();
    final ownWindows =
        windows.where((s) => s.applicationName == ownApplication).toList();
    expect(displays, isNotEmpty, reason: 'no display in the snapshot');
    expect(ownWindows, isNotEmpty, reason: "no window of $ownApplication");

    final firstFrames = <Map<String, Object?>>[];
    final failures = <Map<String, Object?>>[];

    Future<bool> select(XScreenSource source) async {
      final tile = find.byKey(
        ScreenSourcesPage.sourceTileKey(source.kind, source.id),
      );
      final elapsed = Stopwatch()..start();
      Object? thrown;
      var rendered = false;
      try {
        await tester.scrollUntilVisible(
          tile,
          120,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 200,
        );
        await tester.tap(tile);
        rendered = await pumpUntil(
          tester,
          () =>
              find.byKey(ScreenSourcesPage.firstFrameKey).evaluate().isNotEmpty,
          firstFrameBudget,
        );
      } catch (e) {
        thrown = e;
      }
      elapsed.stop();
      final entry = {
        'kind': source.kind.name,
        'id': source.id,
        'title': source.title,
        'firstFrameMs': elapsed.elapsedMilliseconds,
        'status': rendered ? 'rendered' : 'no first frame',
        if (thrown != null) 'thrown': '$thrown',
        if (!rendered)
          'pageError': find
              .byWidgetPredicate((w) =>
                  w is Text && (w.data ?? '').startsWith('capture failed:'))
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .join(),
      };
      (rendered ? firstFrames : failures).add(entry);
      return rendered;
    }

    for (final source in [displays.first, ownWindows.first]) {
      var rendered = await select(source);
      if (!rendered) rendered = await select(source);
      if (!rendered) {
        final fresh =
            primedPairs(await ScreenSourcesPage.captureStackSources());
        evidence['firstFrames'] = firstFrames;
        evidence['captureFailures'] = failures;
        expect(
          fresh.contains(pairOf(source)),
          isFalse,
          reason: 'capability A fails: ${source.kind.name} ${source.id} '
              '"${source.title}" is still enumerated and never captures',
        );
      }
    }
    evidence['firstFrames'] = firstFrames;
    evidence['captureFailures'] = failures;

    final uiDisplays = tester.binding.platformDispatcher.displays;
    final scales = uiDisplays.map((d) => d.devicePixelRatio).toList();
    final applications = {
      for (final window in windows)
        if (window.applicationName != null) window.applicationName!,
    };
    evidence['host'] = {
      'displayCount': uiDisplays.length,
      'devicePixelRatios': scales,
      'primedScreens': primings.last
          .where((s) => s.type == SourceType.Screen)
          .length,
      'primedWindows': primings.last
          .where((s) => s.type == SourceType.Window)
          .length,
      'snapshotDisplays': displays.length,
      'snapshotWindows': windows.length,
      'windowApplications': applications.toList(),
      'listWallTimeMs': [
        for (final recorded in backend.calls) recorded.elapsed.inMilliseconds,
      ],
      'residentBytes': ProcessInfo.currentRss,
      'peakResidentBytes': ProcessInfo.maxRss,
    };

    Map<String, Object?> row(String name, bool exercised, String detail) => {
          'row': name,
          'status': exercised ? 'exercised' : 'host-limited',
          'detail': detail,
        };
    evidence['matrix'] = [
      row('multi-display', uiDisplays.length >= 2,
          'displays: ${uiDisplays.length}'),
      row(
        'Retina and non-Retina pair',
        scales.any((s) => s > 1) && scales.any((s) => s <= 1),
        'devicePixelRatios: $scales',
      ),
      row("three applications' windows", applications.length >= 3,
          'window-owning applications: ${applications.length}'),
      row(
        '40-source latency and memory',
        snapshot.length >= 40,
        'sources: ${snapshot.length}, list: '
            '${call.elapsed.inMilliseconds} ms, rss: ${ProcessInfo.currentRss}',
      ),
    ];
  }, timeout: const Timeout(Duration(minutes: 5)));
}
