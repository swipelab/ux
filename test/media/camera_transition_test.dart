import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';
import 'package:ux/gallery.dart';
import 'package:ux/media.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';

import 'camera_test_backend.dart';
import 'fake_host.dart';
import 'test_fonts.dart';

class _Home with Screen<void> {
  @override
  Widget buildPresenter(BuildContext context) => const Material(
    color: Color(0xFF475467),
    child: Center(child: Text('Conversation')),
  );
}

class _Host extends FakeMediaHost implements ScreenHost {
  _Host(this.navigator);

  final bool navigator;
  final navigatorKey = GlobalKey<NavigatorState>();
  final boundary = GlobalKey();
  late final router = XRouter(home: _Home());
  final screens = <Screen>[];

  @override
  bool isWideScreen(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 600;

  @override
  Future<T?> push<T>(Screen<T> screen) {
    screens.add(screen);
    if (!navigator) return router.push(screen);
    screen.parentHost = this;
    final result = screen.future;
    navigatorKey.currentState!.push(_MediaRoute(screen));
    return result;
  }

  Widget get app => MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorKey: navigatorKey,
    builder: (context, child) => RepaintBoundary(key: boundary, child: child),
    home: navigator
        ? Builder(builder: _Home().buildPresenter)
        : ListenableBuilder(
            listenable: router.stack,
            builder: (context, _) => router.build(context),
          ),
  );
}

class _MediaRoute<T> extends PageRoute<T> {
  _MediaRoute(this.screen);
  final Screen<T> screen;
  late final slot = ScreenSlot(page: screen, controller: controller!);
  bool active = false;
  bool pushed = false;

  @override
  bool get opaque => screen is! SheetScreen;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => screen.transitionDuration;

  void setActive(bool value) {
    if (active == value) return;
    active = value;
    value ? screen.onActive() : screen.onInactive();
  }

  @override
  TickerFuture didPush() {
    screen.detach = () {
      if (isCurrent) {
        navigator!.pop();
      } else {
        navigator!.removeRoute(this);
      }
    };
    screen.removed = () => Dispose.object(screen);
    screen.onPush();
    pushed = true;
    setActive(true);
    return super.didPush();
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    if (pushed) setActive(nextRoute == null && !screen.popped);
    super.didChangeNext(nextRoute);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    setActive(true);
    super.didPopNext(nextRoute);
  }

  @override
  void didComplete(T? result) {
    setActive(false);
    screen.detach = null;
    if (!screen.popped) screen.pop(result);
    super.didComplete(result);
  }

  @override
  void dispose() {
    setActive(false);
    screen.detach = null;
    if (!screen.popped) screen.pop();
    screen.onRemoved();
    slot.focusScope.dispose();
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Material(
    type: MaterialType.transparency,
    child: ScreenBackHandler(
      entry: slot,
      enabled: ModalRoute.isCurrentOf(context)! && screen.canPop,
      onPop: screen.pop,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadMediaTestFonts);
  late CameraTestBackend camera;
  late XGalleryBackend oldGallery;
  late _Host host;

  Future<void> mount(
    WidgetTester tester,
    bool navigator, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    camera = CameraTestBackend();
    XCameraBackend.instance = camera;
    oldGallery = XGallery.backend;
    final thumbnail = File('test/media/fixtures/capture.png').readAsBytesSync();
    XGallery.backend = FakeXGalleryBackend(
      recents: List.generate(
        12,
        (i) => XAsset(
          id: '$i',
          kind: XAssetKind.image,
          width: 12,
          height: 8,
          createdAt: DateTime(2026),
        ),
      ),
      thumbnailFor: (_, _) =>
          XAssetThumbnail(bytes: thumbnail, width: 12, height: 8),
    );
    host = _Host(navigator);
    MediaHost.current = host;
    await tester.pumpWidget(host.app);
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(thumbnail),
        host.navigatorKey.currentContext!,
      ),
    );
    host.push(MediaPickerPage(filter: XAssetKind.image));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    for (final screen in host.screens.reversed) {
      if (!screen.popped) screen.pop();
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox());
    host.router.dispose();
    host.lifecycle.dispose();
    await tester.pumpAndSettle();
    expect(camera.liveHandles, isEmpty);
    expect(camera.listeners, 0);
    XCameraBackend.instance = MethodChannelXCameraBackend();
    XGallery.backend = oldGallery;
  }

  List<int> paintedTextures() {
    final textures = <int>[];
    void visit(Layer layer) {
      if (layer is TextureLayer) textures.add(layer.textureId);
      if (layer is ContainerLayer) {
        Layer? child = layer.firstChild;
        while (child != null) {
          visit(child);
          child = child.nextSibling;
        }
      }
    }

    visit(
      (host.boundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .debugLayer!,
    );
    return textures;
  }

  void expectRect(Rect actual, Rect expected) {
    expect(actual.left, closeTo(expected.left, .01));
    expect(actual.top, closeTo(expected.top, .01));
    expect(actual.width, closeTo(expected.width, .01));
    expect(actual.height, closeTo(expected.height, .01));
  }

  for (final navigator in [false, true]) {
    final name = navigator ? 'navigator' : 'screen_stack';
    testWidgets('$name short camera keeps controls above the preview', (
      tester,
    ) async {
      await mount(tester, navigator, size: const Size(375, 667));
      try {
        await tester.tap(find.byType(CameraThumb));
        await tester.pumpAndSettle();
        expect(
          tester
              .getRect(find.byType(CameraThumb))
              .overlaps(tester.getRect(find.byType(CameraButton))),
          isTrue,
        );
        await expectLater(
          find.byKey(host.boundary),
          matchesGoldenFile('goldens/camera_${name}_short_rest.png'),
        );
      } finally {
        await close(tester);
      }
    });

    testWidgets('$name close paints the cell on the flight removal frame', (
      tester,
    ) async {
      await mount(tester, navigator);
      try {
        final textureId = tester
            .widget<Texture>(find.byType(Texture))
            .textureId;
        await tester.tap(find.byType(CameraThumb));
        await tester.pumpAndSettle();
        (host.screens.last as CameraPage).pop();
        await tester.pump();
        final frames = <int, List<int>>{0: paintedTextures()};
        for (var ms = 16; ms <= 336; ms += 16) {
          await tester.pump(const Duration(milliseconds: 16));
          frames[ms] = paintedTextures();
          if (ms == 304) {
            expect(find.byType(CameraButton), findsNothing);
            await expectLater(
              find.byKey(host.boundary),
              matchesGoldenFile('goldens/camera_${name}_close_removed.png'),
            );
          }
        }
        for (final frame in frames.entries) {
          expect(frame.value, [
            textureId,
          ], reason: 'close frame ${frame.key} ms');
        }
        expect(camera.createCalls, hasLength(1));
        expect(camera.disposeCalls, isEmpty);
      } finally {
        await close(tester);
      }
    });

    testWidgets('$name camera flies on open and close with one texture', (
      tester,
    ) async {
      await mount(tester, navigator);
      try {
        final CameraCellSource cellSource = tester
            .widget<CameraCell>(find.byType(CameraCell))
            .source;
        final source = cellSource.rect!;
        expectRect(source, tester.getRect(find.byType(CameraThumb)));
        const target = Rect.fromLTWH(0, 162, 390, 520);
        final session = tester
            .widget<CameraThumb>(find.byType(CameraThumb))
            .controller;
        final controller = session.value!;
        final textureId = controller.textureId;
        await tester.tap(find.byType(CameraThumb));
        await tester.pump();
        final cameraPage = host.screens.last as CameraPage;
        expect(cameraPage.cellSource, same(cellSource));
        expect(find.byType(CameraThumb), findsOneWidget);
        expect(paintedTextures(), [textureId]);
        await expectLater(
          find.byKey(host.boundary),
          matchesGoldenFile('goldens/camera_${name}_open_0.png'),
        );
        await tester.pump();
        final previewElement = find.byType(CameraThumb).evaluate().single;
        final shutter = tester.getRect(find.byType(CameraButton));

        Future<void> frame(
          String direction,
          int milliseconds,
          double value,
        ) async {
          if (milliseconds != 0) {
            await tester.pump(const Duration(milliseconds: 75));
          }
          final curve = direction == 'close'
              ? Curves.easeOutCubic.flipped
              : Curves.easeOutCubic;
          final t = curve.transform(value);
          await expectLater(
            find.byKey(host.boundary),
            matchesGoldenFile(
              'goldens/camera_${name}_${direction}_$milliseconds.png',
            ),
          );
          expectRect(
            tester.getRect(find.byType(CameraThumb)),
            Rect.lerp(source, target, t)!,
          );
          expect(
            tester
                .widget<CameraThumb>(find.byType(CameraThumb))
                .controller
                .value,
            same(controller),
          );
          final textures = find.byType(Texture);
          expect(textures, findsOneWidget);
          expect(tester.widget<Texture>(textures).textureId, textureId);
          expect(paintedTextures(), [textureId]);
          expect(camera.createCalls, hasLength(1));
          expect(camera.disposeCalls, isEmpty);
          if (direction != 'close' || milliseconds != 300) {
            expect(
              find.byType(CameraThumb).evaluate().single,
              same(previewElement),
            );
            expectRect(tester.getRect(find.byType(CameraButton)), shutter);
            final clip = tester.widget<ClipRRect>(
              find
                  .ancestor(
                    of: find.byType(CameraThumb),
                    matching: find.byType(ClipRRect),
                  )
                  .first,
            );
            expect(clip.borderRadius, BorderRadius.circular(8 * (1 - t)));
          }
        }

        for (final ms in [0, 75, 150, 225, 300]) {
          await frame('open', ms, ms / 300);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(CupertinoIcons.xmark).last);
        expect(cameraPage.popped, isTrue);
        await tester.pump();
        for (final ms in [0, 75, 150, 225, 300]) {
          await frame('close', ms, 1 - ms / 300);
        }
        expect((host.screens.first as MediaPickerPage).popped, isFalse);
      } finally {
        await close(tester);
      }
    });

    testWidgets('$name wide camera flies into the centered card', (
      tester,
    ) async {
      await mount(tester, navigator, size: const Size(900, 720));
      try {
        final source = tester.getRect(find.byType(CameraThumb));
        const target = Rect.fromLTWH(180, 157.5, 540, 405);
        await tester.tap(find.byType(CameraThumb));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final midpoint = Rect.lerp(
          source,
          target,
          Curves.easeOutCubic.transform(.5),
        )!;
        await expectLater(
          find.byKey(host.boundary),
          matchesGoldenFile('goldens/camera_${name}_wide_open_150.png'),
        );
        expectRect(tester.getRect(find.byType(CameraThumb)), midpoint);
        await tester.pumpAndSettle();
        expectRect(tester.getRect(find.byType(CameraThumb)), target);
        (host.screens.last as CameraPage).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expectRect(
          tester.getRect(find.byType(CameraThumb)),
          Rect.lerp(source, target, Curves.easeOutCubic.flipped.transform(.5))!,
        );
        await expectLater(
          find.byKey(host.boundary),
          matchesGoldenFile('goldens/camera_${name}_wide_close_150.png'),
        );
        await tester.pumpAndSettle();
        expectRect(tester.getRect(find.byType(CameraThumb)), source);
        expect(camera.createCalls, hasLength(1));
      } finally {
        await close(tester);
      }
    });

    testWidgets(
      '$name reverses an interrupted flight and reopens the same session',
      (tester) async {
        await mount(tester, navigator);
        try {
          final source = tester.getRect(find.byType(CameraThumb));
          final controller = tester
              .widget<CameraThumb>(find.byType(CameraThumb))
              .controller
              .value;
          await tester.tap(find.byType(CameraThumb));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 75));
          final before = tester.getRect(find.byType(CameraThumb));
          (host.screens.last as CameraPage).pop();
          await tester.pump();
          expectRect(tester.getRect(find.byType(CameraThumb)), before);
          await tester.pumpAndSettle();
          expectRect(tester.getRect(find.byType(CameraThumb)), source);
          await tester.tap(find.byType(CameraThumb));
          await tester.pumpAndSettle();
          expect(
            (host.screens.last as CameraPage).session.value,
            same(controller),
          );
          expect(camera.createCalls, hasLength(1));
          expect(find.byType(Texture), findsOneWidget);
        } finally {
          await close(tester);
        }
      },
    );
  }
}
