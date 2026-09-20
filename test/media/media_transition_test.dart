import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

class _Source implements GallerySource {
  _Source(this.currentRect, this.capture);
  @override
  final Rect? currentRect;
  final Future<ui.Image?> Function() capture;
  @override
  BorderRadius get borderRadius => BorderRadius.circular(16);
  @override
  Future<ui.Image?> snapshot() => capture();
}

class _ProbePage with Screen<void> {
  _ProbePage(
    this.snapshot,
    this.source, {
    bool ready = true,
    this.fromSource = true,
  }) : ready = ValueNotifier(ready);
  final ui.Image snapshot;
  final bool fromSource;
  final GallerySource? source;
  final ValueNotifier<bool> ready;
  @override
  Duration get transitionDuration => kMediaFlightDuration;
  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) => GalleryTransition(
    animation: animation,
    snapshot: fromSource ? snapshot : null,
    sourceRect: fromSource ? const Rect.fromLTWH(22, 650, 80, 90) : null,
    sourceRadius: BorderRadius.circular(8),
    closeSourceLookup: () => source,
    child: child,
  );
  @override
  Widget buildPresenter(BuildContext context) => Stack(
    children: [
      const Positioned.fill(
        child: MediaFlightChrome(child: ColoredBox(color: Colors.black)),
      ),
      const Positioned(
        top: 18,
        left: 20,
        child: MediaFlightChrome(
          child: Text('Close', style: TextStyle(color: Colors.white)),
        ),
      ),
      Positioned(
        left: 70,
        top: 150,
        width: 180,
        height: 240,
        child: ValueListenableBuilder<bool>(
          valueListenable: ready,
          builder: (_, loaded, _) => MediaFlightSurface(
            ready: loaded,
            child: ColoredBox(color: loaded ? Colors.blue : Colors.transparent),
          ),
        ),
      ),
    ],
  );
  @override
  void onRemoved() {
    snapshot.dispose();
    ready.dispose();
    super.onRemoved();
  }
}

Future<ui.Image> _snapshot(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        File('test/media/fixtures/capture.png').readAsBytesSync(),
      );
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      return image;
    }))!;

Rect? _paintedRect(WidgetTester tester) {
  final dynamic state = tester.state(find.byType(GalleryTransition));
  return state.paintedRectForTest as Rect?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadMediaTestFonts);

  for (final (navigator, wide) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    final name = wide
        ? 'navigator_wide'
        : navigator
        ? 'navigator'
        : 'screen_stack';
    testWidgets(
      '$name picker flight and removal preserve selected thumbnail ownership',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1024, 768)
            : const Size(390, 844);
        if (wide) {
          tester.view.viewPadding = const FakeViewPadding(
            left: 20,
            top: 30,
            right: 20,
            bottom: 20,
          );
          addTearDown(tester.view.resetViewPadding);
        }
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final camera = CameraTestBackend();
        XCameraBackend.instance = camera;
        final oldGallery = XGallery.backend;
        final file = File('test/media/fixtures/capture.png');
        final bytes = file.readAsBytesSync();
        final asset = XAsset(
          id: 'photo',
          kind: XAssetKind.image,
          width: 12,
          height: 8,
          createdAt: DateTime(2026),
        );
        var failFile = false;
        XGallery.backend = FakeXGalleryBackend(
          recents: [asset],
          thumbnailFor: (_, _) =>
              XAssetThumbnail(bytes: bytes, width: 12, height: 8),
          fileFor: (_) {
            if (failFile) throw StateError('Asset unavailable');
            return file;
          },
        );
        final host = _Host(navigator);
        MediaHost.current = host;
        final liveImages = <ui.Image>{};
        ui.Image.onCreate = liveImages.add;
        ui.Image.onDispose = liveImages.remove;
        try {
          await tester.pumpWidget(host.app);
          final picker = MediaPickerPage(filter: XAssetKind.image);
          host.push(picker);
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => precacheImage(
              MemoryImage(bytes),
              host.navigatorKey.currentContext!,
            ),
          );
          picker.selection.toggle(asset);
          picker.toggleDisplayMode();
          await tester.pumpAndSettle();
          final before = liveImages.length;
          if (!navigator) {
            failFile = true;
            await tester.runAsync(() async {
              await expectLater(picker.handleAssetTap(asset), throwsStateError);
            });
            expect(liveImages.length, before);
            failFile = false;
          }
          int? retained;
          for (var cycle = 0; cycle < 3; cycle++) {
            late Future<void> opening;
            await tester.runAsync(() async {
              opening = picker.handleAssetTap(asset);
              await Future<void>.delayed(const Duration(milliseconds: 20));
            });
            await tester.pump();
            await tester.runAsync(() async {
              await (host.screens.last as ComposePage).focusedEntry
                  .ensureSource();
            });
            await tester.pump();
            expect(HiddenMediaController.instance.isHidden(asset.id), isTrue);
            final compose = host.screens.last as ComposePage;
            expect(compose.transitionDuration, kMediaFlightDuration);
            if (cycle == 0) {
              for (final ms in [0, 75, 150, 225, 300]) {
                if (ms > 0) await tester.pump(const Duration(milliseconds: 75));
                await expectLater(
                  find.byKey(host.boundary),
                  matchesGoldenFile('goldens/media_${name}_open_$ms.png'),
                );
              }
            } else {
              await tester.pumpAndSettle();
            }
            await tester.pumpAndSettle();
            if (cycle == 2) {
              final carrier = tester.state<DismissCarrierState>(
                find.byType(DismissCarrier),
              );
              carrier.applyExternalDrag(280);
              await tester.pump();
              final dynamic transition = tester.state(
                find.byType(GalleryTransition),
              );
              final rect = transition.mediaRectForTest as Rect;
              carrier.commitExternalDragEnd(0);
              await tester.pump();
              await tester.pump();
              expect(transition.closeSourceRectForTest, rect);
              await expectLater(
                find.byKey(host.boundary),
                matchesGoldenFile('goldens/media_${name}_scaled_close_0.png'),
              );
            } else {
              compose.handleCancel();
              await tester.pump();
            }
            if (cycle == 0) {
              for (final ms in [0, 75, 150, 225, 300]) {
                if (ms > 0) await tester.pump(const Duration(milliseconds: 75));
                await expectLater(
                  find.byKey(host.boundary),
                  matchesGoldenFile('goldens/media_${name}_close_$ms.png'),
                );
              }
              await tester.pump(const Duration(milliseconds: 1));
              await expectLater(
                find.byKey(host.boundary),
                matchesGoldenFile('goldens/media_${name}_removed.png'),
              );
            } else {
              await tester.pumpAndSettle();
            }
            await tester.pump(const Duration(milliseconds: 1));
            expect(HiddenMediaController.instance.hidden, isNull);
            expect(picker.selection.picked, [asset]);
            expect(compose.disposed, isTrue);
            await tester.runAsync(() => opening);
            await tester.pumpAndSettle();
            expect(liveImages.length, lessThanOrEqualTo(before + 2));
            retained ??= liveImages.length;
            expect(liveImages.length, retained);
          }
          picker.pop();
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          host.router.dispose();
          host.lifecycle.dispose();
          expect(camera.liveHandles, isEmpty);
          expect(camera.listeners, 0);
          expect(HiddenMediaController.instance.hasListeners, isFalse);
        } finally {
          ui.Image.onCreate = null;
          ui.Image.onDispose = null;
          XCameraBackend.instance = MethodChannelXCameraBackend();
          XGallery.backend = oldGallery;
          HiddenMediaController.instance.clearForTest();
        }
      },
    );
  }
  testWidgets('without an opening source the image fades at its destination', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = _Host(false);
    MediaHost.current = host;
    await tester.pumpWidget(host.app);
    host.push(_ProbePage(await _snapshot(tester), null, fromSource: false));
    await tester.pump();
    final rect = _paintedRect(tester);
    await tester.pump(const Duration(milliseconds: 75));
    expect(_paintedRect(tester), rect);
    await expectLater(
      find.byKey(host.boundary),
      matchesGoldenFile('goldens/media_no_source_open_75.png'),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    host.router.dispose();
    host.lifecycle.dispose();
  });

  testWidgets(
    'late pixels preserve the source until a continuous handoff; an absent destination shrinks in place',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host(false);
      MediaHost.current = host;
      await tester.pumpWidget(host.app);
      final page = _ProbePage(await _snapshot(tester), null, ready: false);
      host.push(page);
      await tester.pump();
      await tester.pump(kMediaFlightDuration);
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_delayed_300.png'),
      );
      page.ready.value = true;
      await tester.pump();
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_delayed_arrival.png'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 37));
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_delayed_blend.png'),
      );
      await tester.pumpAndSettle();
      page.pop();
      await tester.pump();
      final initial = _paintedRect(tester)!;
      await tester.pump(const Duration(milliseconds: 150));
      final middle = _paintedRect(tester)!;
      expect(middle.center, initial.center);
      expect(middle.width, lessThan(initial.width));
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_missing_close_150.png'),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      host.router.dispose();
      host.lifecycle.dispose();
    },
  );

  testWidgets(
    'an offscreen destination and rejected snapshot shrink at the current image',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host(false);
      MediaHost.current = host;
      await tester.pumpWidget(host.app);
      final page = _ProbePage(
        await _snapshot(tester),
        _Source(
          const Rect.fromLTWH(0, -500, 80, 90),
          () => Future<ui.Image?>.error(StateError('capture unavailable')),
        ),
      );
      host.push(page);
      await tester.pumpAndSettle();
      page.pop();
      await tester.pump();
      final initial = _paintedRect(tester)!;
      await tester.pump(const Duration(milliseconds: 150));
      expect(_paintedRect(tester)!.center, initial.center);
      expect(_paintedRect(tester)!.width, lessThan(initial.width));
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_offscreen_close_150.png'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      host.router.dispose();
      host.lifecycle.dispose();
    },
  );

  testWidgets(
    'a partially visible destination still receives the current image when capture fails',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host(false);
      MediaHost.current = host;
      await tester.pumpWidget(host.app);
      const target = Rect.fromLTWH(-40, 100, 80, 90);
      var captures = 0;
      final page = _ProbePage(
        await _snapshot(tester),
        _Source(target, () {
          captures++;
          return Future<ui.Image?>.error(StateError('capture unavailable'));
        }),
      );
      host.push(page);
      await tester.pumpAndSettle();
      page.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_partial_close_150.png'),
      );
      await tester.pump(const Duration(milliseconds: 149));
      final landed = _paintedRect(tester)!;
      expect(landed.left, closeTo(target.left, .001));
      expect(landed.top, closeTo(target.top, .001));
      expect(landed.width, closeTo(target.width, .001));
      expect(captures, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      host.router.dispose();
      host.lifecycle.dispose();
    },
  );

  testWidgets(
    'interruption preserves the moving pixels; late captures are disposed after removal',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = _Host(false);
      MediaHost.current = host;
      await tester.pumpWidget(host.app);
      final capture = Completer<ui.Image?>();
      final page = _ProbePage(
        await _snapshot(tester),
        _Source(const Rect.fromLTWH(22, 650, 80, 90), () => capture.future),
      );
      host.push(page);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final before = _paintedRect(tester);
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_interrupted.png'),
      );
      page.pop();
      await tester.pump();
      expect(_paintedRect(tester), before);
      await expectLater(
        find.byKey(host.boundary),
        matchesGoldenFile('goldens/media_interrupted.png'),
      );
      await tester.pumpAndSettle();
      final late = await _snapshot(tester);
      capture.complete(late);
      await tester.pump();
      expect(late.debugDisposed, isTrue);
      await tester.pumpWidget(const SizedBox());
      host.router.dispose();
      host.lifecycle.dispose();
    },
  );
}
