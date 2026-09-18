import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/testing.dart';
import 'package:ux/screen_sources.dart';

XScreenSource _source(String id, {Uint8List? thumbnailPng}) => XScreenSource(
      id: id,
      kind: XScreenSourceKind.window,
      title: id,
      sourceWidth: 800,
      sourceHeight: 600,
      thumbnailPng: thumbnailPng,
    );

void main() {
  test('serves the scripted snapshot and records the call', () async {
    final fake = FakeXScreenSourcesBackend(
      sources: [
        _source('window:1', thumbnailPng: Uint8List.fromList([1]))
      ],
    );

    final sources = await fake.list(
      allowedDisplayIds: const {'display:1'},
      allowedWindowIds: const {'window:1'},
      thumbnailWidth: 640,
      thumbnailHeight: 360,
    );

    expect(sources.single.id, 'window:1');
    expect(sources.single.thumbnailPng, [1]);
    expect(fake.listCalls.single.allowedDisplayIds, {'display:1'});
    expect(fake.listCalls.single.allowedWindowIds, {'window:1'});
    expect(fake.listCalls.single.thumbnailWidth, 640);
    expect(fake.listCalls.single.thumbnailHeight, 360);
  });

  test('is picker-driven until scripted otherwise', () {
    final fake = FakeXScreenSourcesBackend();

    expect(fake.captureMode, XScreenCaptureMode.pickerDriven);

    fake.captureMode = XScreenCaptureMode.consentDriven;

    expect(fake.captureMode, XScreenCaptureMode.consentDriven);
  });

  test('an unsupported fake still names its capture mode', () {
    final fake = FakeXScreenSourcesBackend(
      captureMode: XScreenCaptureMode.consentDriven,
      supported: false,
    );

    expect(fake.captureMode, XScreenCaptureMode.consentDriven);
  });

  test('records the default thumbnail size', () async {
    final fake = FakeXScreenSourcesBackend();

    await fake.list(allowedDisplayIds: const {}, allowedWindowIds: const {});

    expect(fake.listCalls.single.thumbnailWidth, 320);
    expect(fake.listCalls.single.thumbnailHeight, 180);
  });

  test('a swapped snapshot is what the next list returns', () async {
    final fake = FakeXScreenSourcesBackend(sources: [_source('window:1')]);

    fake.sources = [_source('window:2'), _source('window:3')];
    final sources = await fake.list(
      allowedDisplayIds: const {},
      allowedWindowIds: const {},
    );

    expect(sources.map((s) => s.id), ['window:2', 'window:3']);
  });

  test('a scripted list error is thrown and still recorded', () async {
    final fake = FakeXScreenSourcesBackend()
      ..listError = const XScreenSourcesException('thumbnail_failed', 'all');

    await expectLater(
      fake.list(allowedDisplayIds: const {}, allowedWindowIds: const {}),
      throwsA(
        isA<XScreenSourcesException>()
            .having((e) => e.code, 'code', 'thumbnail_failed'),
      ),
    );
    expect(fake.listCalls, hasLength(1));
  });

  test('a granting request flips hasPermission', () async {
    final fake = FakeXScreenSourcesBackend();

    expect(await fake.hasPermission(), isFalse);
    expect(await fake.requestPermission(), isTrue);
    expect(await fake.hasPermission(), isTrue);
    expect(fake.hasPermissionCalls, 2);
    expect(fake.requestPermissionCalls, 1);
  });

  test('a refused request leaves permission ungranted', () async {
    final fake = FakeXScreenSourcesBackend()..requestPermissionResult = false;

    expect(await fake.requestPermission(), isFalse);
    expect(await fake.hasPermission(), isFalse);
  });

  test('scripted permission errors are thrown', () async {
    final fake = FakeXScreenSourcesBackend()
      ..hasPermissionError = const XScreenSourcesException('permission_denied')
      ..requestPermissionError =
          const XScreenSourcesException('permission_denied');

    await expectLater(
        fake.hasPermission(), throwsA(isA<XScreenSourcesException>()));
    await expectLater(
      fake.requestPermission(),
      throwsA(isA<XScreenSourcesException>()),
    );
  });

  test('available is scripted and counted', () async {
    final fake = FakeXScreenSourcesBackend(availableResult: false);

    expect(await fake.available(), isFalse);
    fake.availableResult = true;
    expect(await fake.available(), isTrue);
    expect(fake.availableCalls, 2);

    fake.availableError = const XScreenSourcesException('enumeration_failed');
    await expectLater(
      fake.available(),
      throwsA(isA<XScreenSourcesException>()
          .having((e) => e.code, 'code', 'enumeration_failed')),
    );
  });

  test('the share bracket is recorded', () async {
    final fake = FakeXScreenSourcesBackend();

    await fake.startShare(
      notificationTitle: 'Sharing your screen',
      notificationText: 'Tap to return',
    );
    await fake.stopShare();

    expect(
        fake.startShareCalls.single.notificationTitle, 'Sharing your screen');
    expect(fake.startShareCalls.single.notificationText, 'Tap to return');
    expect(fake.stopShareCalls, 1);
  });

  test('scripted bracket errors are thrown and still recorded', () async {
    final fake = FakeXScreenSourcesBackend()
      ..startShareError = const XScreenSourcesException('permission_denied')
      ..stopShareError = const XScreenSourcesException('service_start_failed');

    await expectLater(
      fake.startShare(notificationTitle: 'Sharing your screen'),
      throwsA(isA<XScreenSourcesException>()
          .having((e) => e.code, 'code', 'permission_denied')),
    );
    await expectLater(
      fake.stopShare(),
      throwsA(isA<XScreenSourcesException>()
          .having((e) => e.code, 'code', 'service_start_failed')),
    );
    expect(fake.startShareCalls, hasLength(1));
    expect(fake.stopShareCalls, 1);
  });

  test('an unsupported fake throws unsupported everywhere', () async {
    final fake = FakeXScreenSourcesBackend(supported: false);
    Matcher unsupported() => throwsA(
          isA<XScreenSourcesException>()
              .having((e) => e.code, 'code', 'unsupported'),
        );

    expect(fake.supported, isFalse);
    await expectLater(fake.available(), unsupported());
    await expectLater(fake.hasPermission(), unsupported());
    await expectLater(fake.requestPermission(), unsupported());
    await expectLater(
      fake.list(allowedDisplayIds: const {}, allowedWindowIds: const {}),
      unsupported(),
    );
    await expectLater(
      fake.startShare(notificationTitle: 'Sharing your screen'),
      unsupported(),
    );
    await expectLater(fake.stopShare(), unsupported());
    expect(fake.listCalls, isEmpty);
    expect(fake.startShareCalls, isEmpty);
    expect(fake.stopShareCalls, 0);
  });

  test('it substitutes for the process-wide backend', () async {
    final fake = FakeXScreenSourcesBackend(sources: [_source('window:9')]);
    XScreenSourcesBackend.instance = fake;
    addTearDown(() {
      XScreenSourcesBackend.instance = MethodChannelXScreenSourcesBackend();
    });

    final sources = await XScreenSourcesBackend.instance.list(
      allowedDisplayIds: const {},
      allowedWindowIds: const {},
    );

    expect(sources.single.id, 'window:9');
  });
}
