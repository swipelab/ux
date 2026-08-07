import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';
import 'package:ux_example/screen_sources_page.dart';

class _PrimedSource extends DesktopCapturerSource {
  _PrimedSource(this.id, this.name, this.type);

  @override
  final String id;

  @override
  final String name;

  @override
  final SourceType type;

  @override
  Uint8List? get thumbnail => null;

  @override
  ThumbnailSize get thumbnailSize => ThumbnailSize(0, 0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
    'IQAAAABJRU5ErkJggg==',
  );

  late FakeXScreenSourcesBackend backend;

  setUp(() {
    backend = FakeXScreenSourcesBackend();
    XScreenSourcesBackend.instance = backend;
  });

  tearDown(() {
    XScreenSourcesBackend.instance = MethodChannelXScreenSourcesBackend();
    ScreenSourcesPage.primeSources = ScreenSourcesPage.captureStackSources;
  });

  XScreenSource source(
    String id,
    XScreenSourceKind kind, {
    String title = 'Source',
    Uint8List? thumbnailPng,
    String? applicationName,
  }) =>
      XScreenSource(
        id: id,
        kind: kind,
        title: title,
        sourceWidth: 1920,
        sourceHeight: 1080,
        thumbnailPng: thumbnailPng,
        applicationName: applicationName,
      );

  testWidgets('an ungranted host offers the request and no refresh',
      (tester) async {
    backend.permission = false;
    var primings = 0;
    ScreenSourcesPage.primeSources = () async {
      primings++;
      return const [];
    };

    await tester.pumpWidget(const MaterialApp(home: ScreenSourcesPage()));
    await tester.pumpAndSettle();

    expect(find.text('available: true · permission: false'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);

    await tester.tap(find.text('Request screen recording'));
    await tester.pumpAndSettle();

    expect(backend.requestPermissionCalls, 1);
    expect(primings, 0);
    expect(backend.listCalls, isEmpty);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('a refresh primes the capture stack before it lists, and allows '
      'exactly the ids it primed', (tester) async {
    backend.permission = true;
    final primed = Completer<List<DesktopCapturerSource>>();
    ScreenSourcesPage.primeSources = () => primed.future;

    await tester.pumpWidget(const MaterialApp(home: ScreenSourcesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(backend.listCalls, isEmpty);

    primed.complete([
      _PrimedSource('1', 'Display 1', SourceType.Screen),
      _PrimedSource('2', 'Display 2', SourceType.Screen),
      _PrimedSource('7', 'Editor', SourceType.Window),
      _PrimedSource('2', 'Console', SourceType.Window),
    ]);
    await tester.pumpAndSettle();

    expect(backend.listCalls, hasLength(1));
    expect(backend.listCalls.single.allowedDisplayIds, {'1', '2'});
    expect(backend.listCalls.single.allowedWindowIds, {'7', '2'});
  });

  testWidgets('every source renders its kind, title and thumbnail',
      (tester) async {
    backend.permission = true;
    backend.sources = [
      source('1', XScreenSourceKind.display,
          title: 'Built-in Retina Display', thumbnailPng: onePixelPng),
      source('7', XScreenSourceKind.window,
          title: 'Editor', applicationName: 'Xcode'),
    ];
    ScreenSourcesPage.primeSources = () async => [
          _PrimedSource('1', 'Built-in Retina Display', SourceType.Screen),
          _PrimedSource('7', 'Editor', SourceType.Window),
        ];

    await tester.pumpWidget(const MaterialApp(home: ScreenSourcesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('Built-in Retina Display'), findsOneWidget);
    expect(find.text('display · 1920×1080'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    expect(find.text('window · 1920×1080 · Xcode'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(
          ScreenSourcesPage.sourceTileKey(XScreenSourceKind.display, '1'),
        ),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          ScreenSourcesPage.sourceTileKey(XScreenSourceKind.window, '7'),
        ),
        matching: find.text('no thumbnail'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed snapshot renders its code and message', (tester) async {
    backend.permission = true;
    backend.listError =
        const XScreenSourcesException('permission_denied', 'screen recording');
    ScreenSourcesPage.primeSources = () async =>
        [_PrimedSource('1', 'Display 1', SourceType.Screen)];

    await tester.pumpWidget(const MaterialApp(home: ScreenSourcesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('permission_denied: screen recording'), findsOneWidget);
  });

  testWidgets('a host with nothing to offer renders the empty state',
      (tester) async {
    backend.permission = true;
    ScreenSourcesPage.primeSources = () async => const [];

    await tester.pumpWidget(const MaterialApp(home: ScreenSourcesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(backend.listCalls.single.allowedDisplayIds, isEmpty);
    expect(backend.listCalls.single.allowedWindowIds, isEmpty);
    expect(find.text('No sources.'), findsOneWidget);
  });
}
