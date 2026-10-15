import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';
import 'package:ux/testing.dart';
import 'package:ux_example/camera_permission_page.dart';

void main() {
  late FakeXCameraBackend backend;
  late XCameraBackend original;

  setUp(() {
    original = XCameraBackend.instance;
    backend = FakeXCameraBackend()..cameraPermission = false;
    XCameraBackend.instance = backend;
  });

  tearDown(() => XCameraBackend.instance = original);

  testWidgets('permission actions and foreground changes need no session', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CameraPermissionPage()));
    await tester.pumpAndSettle();
    expect(find.text('Camera access: not granted'), findsOneWidget);
    expect(backend.requestCameraPermissionCalls, 0);

    backend.requestCameraPermissionResult = false;
    await tester.tap(find.text('Request camera access'));
    await tester.pumpAndSettle();
    expect(find.text('Camera access: not granted'), findsOneWidget);
    expect(backend.requestCameraPermissionCalls, 1);

    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(backend.openSettingsCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    backend.cameraPermission = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Camera access: granted'), findsOneWidget);

    backend.cameraPermission = false;
    await tester.tap(find.text('Refresh status'));
    await tester.pumpAndSettle();
    expect(find.text('Camera access: not granted'), findsOneWidget);

    backend.requestCameraPermissionError = const XCameraException(
      'in_progress',
    );
    await tester.tap(find.text('Request camera access'));
    await tester.pumpAndSettle();
    expect(find.text('XCameraException(in_progress)'), findsOneWidget);
    expect(backend.createCalls, isEmpty);
    expect(backend.audioPermissionCalls, 0);
    expect(backend.requestAudioPermissionCalls, 0);

    await tester.pumpWidget(const SizedBox());
    final calls = backend.cameraPermissionCalls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(backend.cameraPermissionCalls, calls);
  });

  testWidgets(
    'a stale or unmounted query cannot replace foreground authorization',
    (tester) async {
      const channel = MethodChannel('ux/camera');
      final queries = <Completer<bool>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) {
        expect(call.method, 'cameraPermissionStatus');
        final result = Completer<bool>();
        queries.add(result);
        return result.future;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      XCameraBackend.instance = MethodChannelXCameraBackend();

      await tester.pumpWidget(const MaterialApp(home: CameraPermissionPage()));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      queries[1].complete(true);
      await tester.pumpAndSettle();
      queries[0].complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Camera access: granted'), findsOneWidget);

      await tester.tap(find.text('Refresh status'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      queries[2].complete(false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
