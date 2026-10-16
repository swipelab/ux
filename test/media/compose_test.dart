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

  @override
  Object? caption(TextEditingController controller) =>
      (controller, controller.text);
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

/// A [width]×[height] PNG whose left half is opaque red.
Future<Uint8List> _halfRedPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
    Paint()..color = const Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<Uint8List> _rgba(ui.Image image) async =>
    (await image.toByteData())!.buffer.asUint8List();

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

  test("each submitted result carries what the host reads from its entry's caption controller", () async {
    final host = _CaptionHost();
    MediaHost.current = host;
    late List<ComposeResult> submitted;
    final page = ComposePage(
      assets: [
        ImageMedia(file: File('meal.jpg')),
        ImageMedia(file: File('soup.jpg')),
      ],
      onSubmit: (results) async {
        submitted = results;
        return ChatSendResult(cids: [], sourceForCid: (_) => null);
      },
    );
    page.entries.first.composerController.text = ' meal ';
    page.entries.last.composerController.text = 'soup';
    await page.handleSubmit();
    expect(submitted.map((r) => r.caption), [
      (host.made.first, ' meal '),
      (host.made.last, 'soup'),
    ]);
    page.dispose();
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

  test(
    'an image entry captured while its preview renders captures its edits',
    () async {
      MediaHost.current = FakeMediaHost();
      final temporary = Directory.systemTemp.createTempSync('ux-compose-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final file = File('${temporary.path}/meal.png')
        ..writeAsBytesSync(await _halfRedPng(4, 2));
      final entry = ComposeEntry(input: ImageMedia(file: file));
      final source = (await entry.ensureSourceForTest())!;
      entry.cropLayer = CropImageLayer(image: source)..rotate90();
      final render = entry.refreshPreviewForTest();
      final capture = (await entry.captureImage())!;
      await render;
      expect(await _rgba(capture), await _rgba(entry.renderedPreview!));
      capture.dispose();
      entry.dispose();
    },
  );

  test(
    'an image entry edited while its preview renders captures the edit',
    () async {
      MediaHost.current = FakeMediaHost();
      final temporary = Directory.systemTemp.createTempSync('ux-compose-');
      addTearDown(() => temporary.deleteSync(recursive: true));
      final file = File('${temporary.path}/meal.png')
        ..writeAsBytesSync(await _halfRedPng(4, 2));
      final entry = ComposeEntry(input: ImageMedia(file: file));
      final source = (await entry.ensureSourceForTest())!;
      entry.entityLayer = EntityLayer(imageSize: entry.sourceSize!)
        ..add(_caption());
      final render = entry.refreshPreviewForTest();
      // The render reads its edits before the crop lands.
      await Future<void>.value();
      entry.cropLayer = CropImageLayer(image: source)..rotate90();
      entry.invalidatePreviewForTest();
      await render;
      final capture = (await entry.captureImage())!;
      entry.invalidatePreviewForTest();
      await entry.refreshPreviewForTest();
      expect(await _rgba(capture), await _rgba(entry.renderedPreview!));
      capture.dispose();
      entry.dispose();
    },
  );

  test('a capture waiting when an edit lands captures the new edits', () async {
    MediaHost.current = FakeMediaHost();
    final temporary = Directory.systemTemp.createTempSync('ux-compose-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final file = File('${temporary.path}/meal.png')
      ..writeAsBytesSync(await _halfRedPng(4, 2));
    final entry = ComposeEntry(input: ImageMedia(file: file));
    final source = (await entry.ensureSourceForTest())!;
    entry.entityLayer = EntityLayer(imageSize: entry.sourceSize!)
      ..add(_caption());
    final render = entry.refreshPreviewForTest();
    final capture = entry.captureImage();
    // The render reads its edits before the crop lands.
    await Future<void>.value();
    entry.cropLayer = CropImageLayer(image: source)..rotate90();
    entry.invalidatePreviewForTest();
    await render;
    final captured = (await capture)!;
    entry.invalidatePreviewForTest();
    await entry.refreshPreviewForTest();
    expect(await _rgba(captured), await _rgba(entry.renderedPreview!));
    captured.dispose();
    entry.dispose();
  });

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

    test('leaves no edit and no file when its draw overlay lands', () async {
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
      expect(temporary.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  });

  group('a video entry with an applied drawing', () {
    const fileChannel = MethodChannel('ux/file');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory temporary;

    setUp(() async {
      MediaHost.current = FakeMediaHost();
      temporary = Directory.systemTemp.createTempSync('ux-compose-');
      final png = await _png(4, 4);
      messenger
        ..setMockMethodCallHandler(
          fileChannel,
          (_) async => {'png': png, 'width': 4, 'height': 4},
        )
        ..setMockMethodCallHandler(pathChannel, (_) async => temporary.path);
    });

    tearDown(() {
      messenger
        ..setMockMethodCallHandler(fileChannel, null)
        ..setMockMethodCallHandler(pathChannel, null);
      temporary.deleteSync(recursive: true);
    });

    /// [entry]'s overlay file once a caption is drawn on it and applied.
    Future<File> applyDrawing(ComposeEntry entry) async {
      await entry.ensureVideoPosterForTest();
      entry.entityLayer ??= EntityLayer(imageSize: entry.sourceSize!)
        ..add(_caption());
      await entry.snapshotDrawOverlayForTest();
      return File(entry.videoEdit.overlay!.path);
    }

    test('deletes its overlay when disposed', () async {
      final entry = ComposeEntry(input: VideoMedia(file: File('clip.mp4')));
      final overlay = await applyDrawing(entry);
      expect(overlay.existsSync(), isTrue);
      entry.dispose();
      expect(overlay.existsSync(), isFalse);
    });

    test('deletes the overlay a second apply replaces', () async {
      final entry = ComposeEntry(input: VideoMedia(file: File('clip.mp4')));
      final first = await applyDrawing(entry);
      final second = await applyDrawing(entry);
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isTrue);
      entry.dispose();
    });

    test('deletes its overlay when an apply clears the drawing', () async {
      final entry = ComposeEntry(input: VideoMedia(file: File('clip.mp4')));
      final overlay = await applyDrawing(entry);
      final layer = entry.entityLayer!;
      layer.remove(layer.entities.single.id);
      await entry.snapshotDrawOverlayForTest();
      expect(entry.videoEdit.overlay, isNull);
      expect(overlay.existsSync(), isFalse);
      entry.dispose();
    });

    test('hands its overlay to the submitted result', () async {
      late List<ComposeResult> submitted;
      final page = ComposePage(
        assets: [VideoMedia(file: File('clip.mp4'))],
        onSubmit: (results) async {
          submitted = results;
          return ChatSendResult(cids: [], sourceForCid: (_) => null);
        },
      );
      final overlay = await applyDrawing(page.entries.single);
      await page.handleSubmit();
      page.dispose();
      expect(submitted.single.videoEdit!.overlay!.path, overlay.path);
      expect(overlay.existsSync(), isTrue);
    });
  });
}
