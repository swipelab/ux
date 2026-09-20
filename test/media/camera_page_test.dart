import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';
import 'package:ux/gallery.dart';
import 'package:ux/media.dart';

import 'camera_test_backend.dart';
import 'fake_host.dart';

Widget _present(CameraPage page) => MaterialApp(
  home: ListenableBuilder(
    listenable: page,
    builder: (context, _) => page.buildPresenter(context),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraTestBackend backend;
  late _Host host;

  setUp(() {
    backend = CameraTestBackend();
    XCameraBackend.instance = backend;
    host = _Host();
    MediaHost.current = host;
  });

  tearDown(() {
    expect(backend.liveHandles, isEmpty);
    expect(backend.listeners, 0);
    expect(host.lifecycle.hasObservers, isFalse);
    host.lifecycle.dispose();
    XCameraBackend.instance = MethodChannelXCameraBackend();
  });

  testWidgets(
    'a borrowed page renders the existing texture and leaves its owner usable',
    (tester) async {
      final session = _Session();
      final original = await session.initialize();
      final page = CameraPage(session: session)..onPush();
      page.onActive();
      await tester.pumpWidget(_present(page));
      expect(page.controller.value, same(original));
      expect(
        tester.widget<Texture>(find.byType(Texture)).textureId,
        original!.textureId,
      );
      expect(backend.createCalls, hasLength(1));
      expect(session.hasObservers, isTrue);
      await tester.pumpWidget(const SizedBox());
      page.pop();
      page.dispose();
      expect(session.hasObservers, isFalse);
      expect(session.disposed, isFalse);
      await session.flipCamera();
      expect(session.value, same(original));
      expect(original.description, backCamera);
      expect(backend.disposeCalls, isEmpty);
      await tester.runAsync(session.dispose);
    },
  );

  test(
    'a recording shared controller refuses page and owner lens changes',
    () async {
      final session = _Session();
      final page = CameraPage(session: session)..onPush();
      await session.initialize();
      await page.takeVideo();
      expect(page.recording, isTrue);
      await page.flipCamera();
      await session.flipCamera();
      expect(backend.setDescriptionCalls, isEmpty);
      expect(session.value!.description, frontCamera);
      page.dispose();
      await session.stopRecording();
      await session.dispose();
    },
  );

  test('still flash fires on the back camera and stays off on the front', () async {
    final page = CameraPage()..onPush();
    await page.session.initialize();
    page.toggleFlash();
    backend.takePictureError = const XCameraException('capture_failed');
    await page.takePhoto();
    expect(backend.setFlashModeCalls.single.mode, XFlashMode.off);
    await page.flipCamera();
    await page.takePhoto();
    expect(backend.setFlashModeCalls.last.mode, XFlashMode.always);
    expect(backend.takePictureCalls, hasLength(2));
    page.dispose();
    await page.session.dispose();
  });

  test(
    'the owner releases its camera while a borrowed still is normalizing',
    () async {
      final session = _Session();
      final page = CameraPage(session: session)..onPush();
      await session.initialize();
      final file = _PendingCaptureFile();
      final capture = io.IOOverrides.runZoned(
        page.takePhoto,
        createFile: (_) => file,
      );
      await file.readStarted.future;
      page.pop();
      page.dispose();
      final closing = session.dispose();
      try {
        await expectLater(
          closing.timeout(const Duration(seconds: 1)),
          completes,
        );
        expect(backend.liveHandles, isEmpty);
        expect(backend.listeners, 0);
      } finally {
        file.bytes.completeError(const io.FileSystemException('capture removed'));
        await capture;
        await closing;
      }
    },
  );

  test(
    'standalone open and cancel cycles release their sessions and listeners',
    () async {
      for (var cycle = 0; cycle < 12; cycle++) {
        final page = CameraPage()..onPush();
        page.onActive();
        await page.session.initialize();
        page.pop();
        page.dispose();
        await page.session.dispose();
        expect(backend.liveHandles, isEmpty);
        expect(backend.listeners, 0);
        expect(host.lifecycle.hasObservers, isFalse);
      }
      expect(backend.createCalls, hasLength(12));
      expect(backend.disposeCalls, hasLength(12));
    },
  );

  test(
    'a borrowed page can close during initialization without closing the owner',
    () async {
      backend.initializeGate = Completer();
      final session = _Session();
      final page = CameraPage(session: session)..onPush();
      await Future<void>.delayed(Duration.zero);
      page.pop();
      page.dispose();
      backend.initializeGate!.complete();
      final controller = await session.initialize();
      expect(controller, isNotNull);
      expect(session.hasObservers, isFalse);
      expect(backend.createCalls, hasLength(1));
      expect(backend.disposeCalls, isEmpty);
      await session.dispose();
    },
  );

  test('standalone disposal during initialization leaves no late page notification', () async {
    backend.initializeGate = Completer();
    final page = CameraPage()..onPush();
    await Future<void>.delayed(Duration.zero);
    page.dispose();
    backend.initializeGate!.complete();
    await page.session.dispose();
    expect(page.controller.value, isNull);
    expect(backend.disposeCalls, [1]);
  });

  test('a borrowed recording canceled during startup stops before the next page uses it', () async {
    final session = _Session();
    await session.initialize();
    final page = CameraPage(session: session)..onPush();
    backend.recordingGate = Completer();
    final starting = page.takeVideo();
    await Future<void>.delayed(Duration.zero);
    expect(backend.startVideoRecordingCalls, hasLength(1));
    page.pop();
    page.dispose();
    backend.recordingGate!.complete();
    await starting;
    final reopened = CameraPage(session: session)..onPush();
    await session.initialize();
    expect(reopened.recording, isFalse);
    expect(backend.stopVideoRecordingCalls, [2]);
    expect(backend.createCalls, hasLength(2));
    expect(session.value!.enableAudio, isTrue);
    reopened.dispose();
    await session.dispose();
  });

  test(
    'disposing an exiting borrower does not stop the next borrower recording',
    () async {
      final session = _Session();
      await session.initialize();
      final exiting = CameraPage(session: session)..onPush();
      await exiting.takeVideo();
      exiting.pop();
      final next = CameraPage(session: session)..onPush();
      await session.initialize();
      await next.takeVideo();
      expect(next.recording, isTrue);
      exiting.dispose();
      await session.initialize();
      expect(next.recording, isTrue);
      expect(backend.stopVideoRecordingCalls, [2]);
      next.dispose();
      await session.stopRecording();
      await session.dispose();
    },
  );

  test('canceling while audio opens does not start a recording on the borrowed owner', () async {
    final session = _Session();
    await session.initialize();
    final page = CameraPage(session: session)..onPush();
    backend.initializeGate = Completer();
    final starting = page.takeVideo();
    await Future<void>.delayed(Duration.zero);
    page.pop();
    page.dispose();
    backend.initializeGate!.complete();
    await starting;
    await session.initialize();
    expect(backend.startVideoRecordingCalls, isEmpty);
    expect(session.value!.enableAudio, isTrue);
    await session.dispose();
  });

  testWidgets(
    'image-only capture has no video switch or long-press recording',
    (tester) async {
      final page = CameraPage(filter: XAssetKind.image)..onPush();
      await page.session.initialize();
      await tester.pumpWidget(_present(page));
      expect(find.byType(PhotoVideoSwap), findsNothing);
      expect(
        tester.widget<CameraButton>(find.byType(CameraButton)).onLongPress,
        isNull,
      );
      page.setPhoto(false);
      await tester.runAsync(page.takeVideo);
      await page.endVideo();
      backend.takePictureError = const XCameraException('capture_failed');
      await tester.longPress(find.byType(CameraButton));
      expect(page.photo, isTrue);
      expect(backend.startVideoRecordingCalls, isEmpty);
      expect(backend.createCalls.single.enableAudio, isFalse);
      await tester.runAsync(page.takePhoto);
      expect(backend.takePictureCalls, isNotEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        page.dispose();
        await page.session.dispose();
      });
    },
  );

  testWidgets(
    'video-only shutter starts and returns a video without still controls',
    (tester) async {
      final page = CameraPage(filter: XAssetKind.video)..onPush();
      await page.session.initialize();
      await tester.pumpWidget(_present(page));
      expect(find.byType(PhotoVideoSwap), findsNothing);
      expect(find.byType(FlashButton), findsNothing);
      expect(page.cameraButtonState, CameraButtonState.video);
      page.setPhoto(true);
      expect(page.photo, isFalse);
      final result = page.future;
      await tester.runAsync(page.takePhoto);
      expect(page.recording, isTrue);
      await tester.runAsync(page.takePhoto);
      expect(
        await result,
        isA<VideoMedia>().having(
          (media) => media.file.path,
          'path',
          backend.videoPath,
        ),
      );
      expect(backend.takePictureCalls, isEmpty);
      expect(backend.stopVideoRecordingCalls, [2]);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        page.dispose();
        await page.session.dispose();
      });
    },
  );

  testWidgets(
    'default capture switches modes and updates the shared owner on audio and lens changes',
    (tester) async {
      final session = _Session();
      final page = CameraPage(session: session)..onPush();
      await session.initialize();
      await tester.pumpWidget(_present(page));
      expect(find.byType(PhotoVideoSwap), findsOneWidget);
      expect(page.photo, isTrue);
      expect(
        tester.widget<CameraButton>(find.byType(CameraButton)).onLongPress,
        isNotNull,
      );
      await page.flipCamera();
      final original = session.value;
      expect(original!.description, backCamera);
      page.setPhoto(false);
      expect(page.photo, isFalse);
      page.setPhoto(true);
      expect(page.photo, isTrue);
      await tester.runAsync(page.takeVideo);
      expect(page.controller.value, same(session.value));
      expect(session.value, isNot(same(original)));
      expect(session.value!.description, backCamera);
      expect(backend.liveHandles, {2});
      await tester.pumpAndSettle();
      expect(
        tester.widget<Texture>(find.byType(Texture)).textureId,
        session.value!.textureId,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        page.dispose();
        await session.stopRecording();
        await session.dispose();
      });
    },
  );
}

class _Session extends CameraSession {
  bool get hasObservers => hasListeners;
}

class _PendingCaptureFile extends Fake implements io.File {
  final readStarted = Completer<void>();
  final bytes = Completer<Uint8List>();

  @override
  Future<Uint8List> readAsBytes() {
    readStarted.complete();
    return bytes.future;
  }
}

class _Host extends FakeMediaHost {
  final _lifecycle = _Lifecycle();
  @override
  _Lifecycle get lifecycle => _lifecycle;
}

class _Lifecycle extends ValueNotifier<AppLifecycleState> {
  _Lifecycle() : super(AppLifecycleState.resumed);
  bool get hasObservers => hasListeners;
}
