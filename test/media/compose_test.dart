import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/media.dart';
import 'package:ux/testing.dart';
import 'package:ux/video.dart';

import 'fake_host.dart';

class _CaptionHost extends FakeMediaHost {
  final made = <TextEditingController>[];

  @override
  TextEditingController captionController() {
    final controller = TextEditingController();
    made.add(controller);
    return controller;
  }
}

/// Holds initialize and disposeInstance while their completer is pending.
class _HeldBackend extends FakeXVideoPlayerBackend {
  Completer<void>? initializeHeld;
  Completer<void>? disposeHeld;

  @override
  Future<XVideoPlayerMetadata> initialize(int handle) async {
    final metadata = await super.initialize(handle);
    await initializeHeld?.future;
    return metadata;
  }

  @override
  Future<void> disposeInstance(int handle) async {
    await disposeHeld?.future;
    await super.disposeInstance(handle);
  }
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

TextEntity _caption() => TextEntity(
  text: 'hi',
  style: TextEntityStyle.regular,
  align: TextAlign.center,
  colour: const Color(0xFFFFFFFF),
  fontSize: .5,
  position: const Offset(2, 2),
  width: 4,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('an entry captions through the host\'s controller', () {
    final host = _CaptionHost();
    MediaHost.current = host;
    final entry = ComposeEntry(input: ImageMedia(file: File('meal.jpg')));
    expect(entry.composerController, same(host.made.single));
    entry.dispose();
  });

  test('a result with bytes resolves to them', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final result = ComposeResult(
      source: ImageMedia(file: File('absent.jpg')),
      composedImage: null,
      imageBytes: Future.value(bytes),
    );
    expect(await result.resolveImageBytes(), same(bytes));
  });

  test('releasing the top hide slot hides the one under it again', () {
    final hidden = HiddenMediaController.instance..clearForTest();
    final under = hidden.acquire('a');
    final top = hidden.acquire('b');
    expect(hidden.isHidden('b'), isTrue);

    hidden.release(top);
    expect(hidden.isHidden('a'), isTrue);

    hidden.release(under);
    expect(hidden.hidden, isNull);
  });

  test(
    'an edited image entry disposed while capturing captures nothing',
    () async {
      MediaHost.current = FakeMediaHost();
      final temporary = Directory.systemTemp.createTempSync('ux-compose-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final file = File('${temporary.path}/meal.png')
        ..writeAsBytesSync(await _png(4, 4));
      final entry = ComposeEntry(input: ImageMedia(file: file));
      await entry.ensureSourceForTest();
      entry.entityLayer = EntityLayer(imageSize: entry.sourceSize!)
        ..add(_caption());
      final capture = entry.captureImage();
      entry.dispose();
      expect(await capture, isNull);
    },
  );

  test('concurrent poster loads of a video entry share one poster', () async {
    const fileChannel = MethodChannel('ux/file');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(fileChannel, null));
    MediaHost.current = FakeMediaHost();
    final entry = ComposeEntry(input: VideoMedia(file: File('clip.mp4')));
    final held = Completer<void>();
    final png = await _png(4, 4);
    messenger.setMockMethodCallHandler(fileChannel, (_) async {
      await held.future;
      return {'png': png, 'width': 4, 'height': 4};
    });
    final loads = [
      entry.ensureVideoPosterForTest(),
      entry.ensureVideoPosterForTest(),
    ];
    held.complete();
    final posters = await Future.wait(loads);
    expect(posters.first, same(entry.source));
    expect(posters.last, same(entry.source));
    entry.dispose();
  });

  group('a video entry disposed mid-flight', () {
    const fileChannel = MethodChannel('ux/file');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late _HeldBackend backend;
    late ComposeEntry entry;

    setUp(() {
      MediaHost.current = FakeMediaHost();
      backend = _HeldBackend();
      XVideoPlayerBackend.instance = backend;
      entry = ComposeEntry(input: VideoMedia(file: File('clip.mp4')));
    });

    tearDown(() {
      XVideoPlayerBackend.instance = MethodChannelXVideoPlayerBackend();
      messenger.setMockMethodCallHandler(fileChannel, null);
      messenger.setMockMethodCallHandler(pathChannel, null);
    });

    test('settles its video load without notifying', () async {
      final held = backend.initializeHeld = Completer<void>();
      final load = entry.ensureVideoInitialized();
      entry.dispose();
      held.complete();
      await load;
    });

    test('settles its video teardown without notifying', () async {
      await entry.ensureVideoInitialized();
      final held = backend.disposeHeld = Completer<void>();
      final teardown = entry.disposeVideo();
      entry.dispose();
      held.complete();
      await teardown;
    });

    test('drops its crop poster', () async {
      final held = Completer<void>();
      final png = await _png(4, 4);
      messenger.setMockMethodCallHandler(fileChannel, (_) async {
        await held.future;
        return {'png': png, 'width': 4, 'height': 4};
      });
      final poster = entry.ensureVideoPosterForTest();
      entry.dispose();
      held.complete();
      expect(await poster, isNull);
      expect(entry.source, isNull);
    });

    test('leaves its edit unset when its draw overlay lands', () async {
      final png = await _png(4, 4);
      messenger.setMockMethodCallHandler(
        fileChannel,
        (_) async => {'png': png, 'width': 4, 'height': 4},
      );
      await entry.ensureVideoPosterForTest();
      entry.entityLayer = EntityLayer(imageSize: entry.sourceSize!)
        ..add(_caption());
      final held = Completer<void>();
      final temporary = Directory.systemTemp.createTempSync('ux-compose-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      messenger.setMockMethodCallHandler(pathChannel, (_) async {
        await held.future;
        return temporary.path;
      });
      final snapshot = entry.snapshotDrawOverlayForTest();
      entry.dispose();
      held.complete();
      await snapshot;
      expect(entry.videoEdit.overlay, isNull);
    });
  });
}
