import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';
import 'package:ux/gallery.dart';
import 'package:ux/media.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';

import 'camera_test_backend.dart';
import 'fake_host.dart';
import 'test_fonts.dart';

XAsset _asset(String id) => XAsset(
  id: id,
  kind: XAssetKind.image,
  width: 12,
  height: 8,
  createdAt: DateTime(2026),
);

class _Lifecycle extends ValueNotifier<AppLifecycleState> {
  _Lifecycle() : super(AppLifecycleState.resumed);
  bool get observed => hasListeners;
  void foreground() {
    value = AppLifecycleState.paused;
    value = AppLifecycleState.resumed;
  }
}

class _Host extends FakeMediaHost implements ScreenHost {
  @override
  _Lifecycle get lifecycle => _lifecycle;
  final _lifecycle = _Lifecycle();
  final pages = ValueNotifier<List<Screen>>([]);
  final pushed = <Screen>[];

  @override
  Future<T?> push<T>(Screen<T> screen) {
    final result = screen.future;
    screen.parentHost = this;
    screen.detach = () => pages.value = [...pages.value]..remove(screen);
    screen.removed = () => Dispose.object(screen);
    screen.onPush();
    pushed.add(screen);
    pages.value = [...pages.value, screen];
    return result;
  }

  Widget get app => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ValueListenableBuilder<List<Screen>>(
      valueListenable: pages,
      builder: (context, pages, _) => ScreenStack(home: _Home(), stack: pages),
    ),
  );
}

class _Home with Screen<void> {
  @override
  Widget buildPresenter(BuildContext context) => const SizedBox.expand();
}

class _Gallery extends FakeXGalleryBackend {
  _Gallery({super.recents, super.albums, super.assetsByAlbum})
    : super(
        thumbnailFor: (_, size) => XAssetThumbnail(
          bytes: File('test/media/fixtures/capture.png').readAsBytesSync(),
          width: 12,
          height: 8,
        ),
        fileFor: (_) => File('test/media/fixtures/capture.png'),
      );

  int permissionCalls = 0;
  int settingsCalls = 0;
  int manageCalls = 0;

  @override
  Future<void> openSettings() async {
    settingsCalls++;
  }

  @override
  Future<void> presentLimitedLibraryPicker() async {
    manageCalls++;
  }

  final queuedPermissions = <Completer<XGalleryPermission>>[];
  final queuedAssets = <Completer<List<XAsset>>>[];
  bool get observed => _subscriptions > 0;
  int _subscriptions = 0;
  late final _changes = StreamController<void>.broadcast(
    onListen: () => _subscriptions++,
    onCancel: () => _subscriptions--,
  );

  @override
  Stream<void> get libraryChanges => _changes.stream;
  @override
  void emitLibraryChange() => _changes.add(null);

  @override
  Future<XGalleryPermission> permission() async {
    permissionCalls++;
    if (queuedPermissions.isNotEmpty) {
      return queuedPermissions.removeAt(0).future;
    }
    return super.permission();
  }

  @override
  Future<List<XAsset>> assets({
    String? albumId,
    XAssetKind? filter,
    required int start,
    required int end,
  }) async {
    if (queuedAssets.isNotEmpty) return queuedAssets.removeAt(0).future;
    return super.assets(
      albumId: albumId,
      filter: filter,
      start: start,
      end: end,
    );
  }
}

class _Camera extends CameraTestBackend {
  final queuedPermissions = <Completer<bool>>[];
  Completer<bool>? requestGate;

  @override
  Future<bool> cameraPermissionGranted() async {
    if (queuedPermissions.isNotEmpty) {
      return queuedPermissions.removeAt(0).future;
    }
    return super.cameraPermissionGranted();
  }

  @override
  Future<bool> requestCameraPermission() async {
    await requestGate?.future;
    return super.requestCameraPermission();
  }
}

Finder _cell(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is PickerGridItem &&
      widget.asset.id == id &&
      widget.viewKind == PickerViewKind.grid,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadMediaTestFonts);
  late _Camera camera;
  late _Gallery gallery;
  late _Host host;
  late Directory temporary;
  late XGalleryBackend originalGallery;

  setUp(() {
    camera = _Camera();
    XCameraBackend.instance = camera;
    originalGallery = XGallery.backend;
    gallery = _Gallery(recents: List.generate(40, (i) => _asset('$i')));
    XGallery.backend = gallery;
    host = _Host();
    MediaHost.current = host;
    temporary = Directory.systemTemp.createTempSync('ux-picker-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temporary.path,
        );
  });

  tearDown(() {
    expect(camera.liveHandles, isEmpty);
    expect(camera.listeners, 0);
    expect(host.lifecycle.observed, isFalse);
    expect(gallery.observed, isFalse);
    host.lifecycle.dispose();
    host.pages.dispose();
    XCameraBackend.instance = MethodChannelXCameraBackend();
    XGallery.backend = originalGallery;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    temporary.deleteSync(recursive: true);
  });

  Future<MediaPickerPage> mount(
    WidgetTester tester, {
    MediaPickerPage? page,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final picker = page ?? MediaPickerPage();
    host.push(picker);
    await tester.pumpWidget(host.app);
    await tester.pumpAndSettle();
    return picker;
  }

  Future<void> expand(WidgetTester tester) async {
    await tester.drag(find.byType(SheetThumb), const Offset(0, -500));
    await tester.pumpAndSettle();
  }

  void pickerTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (final page in host.pushed.reversed) {
          if (!page.popped) page.pop();
          if (page is Disposable && !(page as Disposable).disposed) {
            (page as Disposable).dispose();
          }
        }
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
    });
  }

  pickerTest(
    'the live cell spans two rows and hit testing opens its shared camera',
    (tester) async {
      final picker = await mount(tester);
      await expand(tester);
      final rect = tester.getRect(find.byType(CameraThumb));
      final first = tester.getRect(_cell('0'));
      expect(rect.left, 0);
      expect(rect.width, closeTo(386 / 3, 0.001));
      expect(rect.height, closeTo(first.height * 2 + 2, 0.001));
      expect(first.left, closeTo(rect.right + 2, 0.001));
      expect(first.top, rect.top);
      expect(tester.getTopLeft(_cell('2')).dx, first.left);
      expect(tester.getTopLeft(_cell('4')).dx, 0);
      final controller = tester
          .widget<CameraThumb>(find.byType(CameraThumb))
          .controller
          .value;
      await tester.tapAt(Offset(rect.center.dx, rect.bottom - 20));
      await tester.pumpAndSettle();
      final page = host.pages.value.last as CameraPage;
      expect(page.session.value, same(controller));
      expect(camera.createCalls, hasLength(1));
      page.pop();
      await tester.pumpAndSettle();
      expect(picker.popped, isFalse);
      expect(camera.disposeCalls, isEmpty);
      final scroll = picker.sheetController.activeScrollController!;
      expect(
        scroll.position.maxScrollExtent,
        closeTo(
          14 * (rect.width + 2) - 2 - scroll.position.viewportDimension,
          0.001,
        ),
      );
      expect(find.byType(PickerGridItem).evaluate().length, lessThan(40));
      scroll.jumpTo(600);
      await tester.pumpAndSettle();
      expect(find.byType(CameraThumb), findsNothing);
      scroll.jumpTo(150);
      await tester.pumpAndSettle();
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(camera.createCalls, hasLength(1));
      scroll.jumpTo(0);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(tester.getSize(_cell('0')).width, closeTo(836 / 5, 0.001));
      expect(
        tester.getTopLeft(_cell('4')).dx,
        tester.getTopLeft(_cell('0')).dx,
      );
    },
  );

  pickerTest(
    'granted access without a device uses ordinary asset geometry and extent',
    (tester) async {
      camera.cameras = [];
      gallery = _Gallery(recents: [_asset('0'), _asset('1'), _asset('2')]);
      XGallery.backend = gallery;
      final picker = await mount(tester);
      expect(find.byType(CameraThumb), findsNothing);
      expect(find.byType(PickerCameraBanner), findsNothing);
      expect(
        tester.getTopLeft(_cell('0')).dx,
        tester.getTopLeft(find.byType(CustomScrollView).first).dx,
      );
      expect(
        tester.getTopLeft(_cell('2')).dy,
        tester.getTopLeft(_cell('0')).dy,
      );
      expect(
        picker.sheetController.activeScrollController!.position.maxScrollExtent,
        0,
      );
      expect(camera.createCalls, isEmpty);
    },
  );

  pickerTest(
    'unknown photo permission defers the camera until photo access is granted',
    (tester) async {
      final permission = Completer<XGalleryPermission>();
      gallery.queuedPermissions.add(permission);
      await mount(tester);
      expect(camera.cameraPermissionCalls, 1);
      expect(camera.createCalls, isEmpty);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/picker_photo_permission_pending.png'),
      );
      expect(find.byType(PickerPermissionPlaceholder), findsNothing);
      expect(find.byType(PickerGridItem), findsNothing);
      expect(find.byType(CameraThumb), findsNothing);
      permission.complete(XGalleryPermission.granted);
      await tester.pumpAndSettle();
      expect(find.byType(PickerPermissionPlaceholder), findsNothing);
      expect(_cell('0'), findsOneWidget);
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(camera.liveHandles, {1});
    },
  );

  pickerTest('a delayed photo denial never allocates a camera', (tester) async {
    final permission = Completer<XGalleryPermission>();
    gallery.queuedPermissions.add(permission);
    await mount(tester);
    expect(camera.cameraPermissionCalls, 1);
    expect(camera.createCalls, isEmpty);
    permission.complete(XGalleryPermission.denied);
    await tester.pumpAndSettle();
    expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
    expect(camera.createCalls, isEmpty);
    expect(camera.disposeCalls, isEmpty);
  });

  pickerTest('known photo access waits for the camera permission answer', (
    tester,
  ) async {
    final permission = Completer<bool>();
    camera.queuedPermissions.add(permission);
    await mount(tester);
    expect(_cell('0'), findsOneWidget);
    expect(camera.createCalls, isEmpty);
    permission.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(CameraThumb), findsOneWidget);
    expect(camera.liveHandles, {1});
  });

  pickerTest(
    'camera requests leave photos selectable and recover the preview',
    (tester) async {
      camera.cameraPermission = false;
      final picker = await mount(tester);
      await expand(tester);
      expect(find.byType(PickerCameraBanner), findsOneWidget);
      camera.requestGate = Completer();
      await tester.tap(find.text(host.manage));
      await tester.pump();
      final rect = tester.getRect(_cell('0'));
      await tester.tapAt(rect.topRight + const Offset(-18, 18));
      await tester.pumpAndSettle();
      expect(picker.selection.picked.map((a) => a.id), ['0']);
      camera.requestGate!.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(PickerCameraBanner), findsNothing);
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(camera.requestCameraPermissionCalls, 1);
      expect(picker.selection.count, 1);
    },
  );

  pickerTest(
    'photo recovery reveals the camera even when the authorized album is empty',
    (tester) async {
      gallery = _Gallery()..permissionState = XGalleryPermission.denied;
      XGallery.backend = gallery;
      final picker = await mount(tester);
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
      expect(find.byType(CameraThumb), findsNothing);
      expect(find.byType(PickerCameraBanner), findsNothing);
      await expand(tester);
      expect(camera.liveHandles, isEmpty);
      await tester.tap(find.text(host.openSettings));
      expect(gallery.settingsCalls, 1);
      gallery.permissionState = XGalleryPermission.limited;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      expect(find.byType(PickerPermissionPlaceholder), findsNothing);
      expect(find.byType(PickerLimitedBanner), findsOneWidget);
      await tester.tap(find.text(host.manage));
      expect(gallery.manageCalls, 1);
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(find.byType(PickerGridItem), findsNothing);
      expect(camera.liveHandles, hasLength(1));
      await tester.tap(find.byType(CameraThumb));
      await tester.pumpAndSettle();
      (host.pages.value.last as CameraPage).pop();
      await tester.pumpAndSettle();
      expect(picker.popped, isFalse);
    },
  );

  pickerTest(
    'first photo request replaces the prompt with the library and camera',
    (tester) async {
      gallery.permissionState = XGalleryPermission.notDetermined;
      await mount(tester);
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
      expect(find.byType(CameraThumb), findsNothing);
      expect(find.text(host.openSettings), findsNothing);
      expect(camera.liveHandles, isEmpty);
      await tester.tap(find.text(host.allowPhotoAccess));
      await tester.pumpAndSettle();
      expect(find.byType(PickerPermissionPlaceholder), findsNothing);
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(_cell('0'), findsOneWidget);
      expect(camera.liveHandles, hasLength(1));
    },
  );

  pickerTest(
    'photo library revocation releases the camera and recovery opens a new preview',
    (tester) async {
      await mount(tester);
      expect(camera.liveHandles, {1});
      gallery.permissionState = XGalleryPermission.denied;
      gallery.emitLibraryChange();
      await tester.pumpAndSettle();
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
      expect(find.byType(CameraThumb), findsNothing);
      expect(camera.liveHandles, isEmpty);
      expect(camera.disposeCalls, [1]);

      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      gallery.permissionState = XGalleryPermission.granted;
      gallery.emitLibraryChange();
      await tester.pumpAndSettle();
      expect(find.byType(PickerPermissionPlaceholder), findsNothing);
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(camera.liveHandles, {2});
    },
  );

  pickerTest(
    'photo denial preserves the lent camera until cancellation returns it',
    (tester) async {
      final picker = await mount(tester);
      final opening = picker.handleCameraTap();
      await tester.pumpAndSettle();
      final page = host.pages.value.last as CameraPage;
      final controller = page.controller.value;

      gallery.permissionState = XGalleryPermission.denied;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      expect(host.pages.value.last, same(page));
      expect(camera.liveHandles, {1});
      expect(page.session.disposed, isFalse);
      expect(page.controller.value, same(controller));
      expect(
        tester.widget<Texture>(find.byType(Texture)).textureId,
        controller!.textureId,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/picker_borrowed_camera_photos_denied.png'),
      );

      gallery.permissionState = XGalleryPermission.granted;
      gallery.emitLibraryChange();
      await tester.pumpAndSettle();
      expect(page.controller.value, same(controller));
      expect(camera.createCalls, hasLength(1));
      gallery.permissionState = XGalleryPermission.denied;
      gallery.emitLibraryChange();
      await tester.pumpAndSettle();
      expect(page.session.disposed, isFalse);
      expect(camera.disposeCalls, isEmpty);

      page.pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() => opening);
      await tester.pumpAndSettle();
      expect(page.session.disposed, isTrue);
      expect(camera.liveHandles, isEmpty);
      expect(camera.disposeCalls, [1]);
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
    },
  );

  pickerTest(
    'capture with photos denied releases the loan before compose closes',
    (tester) async {
      camera.picturePath = File('test/media/fixtures/capture.png')
          .absolute
          .path;
      final picker = await mount(tester);
      final opening = picker.handleCameraTap();
      await tester.pumpAndSettle();
      final page = host.pages.value.last as CameraPage;
      gallery.permissionState = XGalleryPermission.denied;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();

      await tester.runAsync(page.takePhoto);
      await tester.pumpAndSettle();
      expect(camera.takePictureCalls, hasLength(1));
      final compose = host.pages.value.last as ComposePage;
      expect(compose.assets.single, isA<ImageMedia>());
      expect(page.session.disposed, isTrue);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(camera.liveHandles, isEmpty);
      expect(camera.disposeCalls, [1]);
      compose.handleCancel();
      await tester.pumpAndSettle();
      await opening;
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
    },
  );

  pickerTest(
    'camera revocation releases a loan and recovery waits for its return',
    (tester) async {
      final picker = await mount(tester);
      final opening = picker.handleCameraTap();
      await tester.pumpAndSettle();
      final page = host.pages.value.last as CameraPage;
      camera.cameraPermission = false;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      expect(page.session.disposed, isTrue);
      expect(page.controller.value, isNull);
      expect(camera.liveHandles, isEmpty);
      expect(camera.disposeCalls, [1]);

      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      camera.cameraPermission = true;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      expect(camera.createCalls, hasLength(1));
      expect(camera.liveHandles, isEmpty);
      page.pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() => opening);
      await tester.pumpAndSettle();
      expect(camera.liveHandles, {2});
      expect(find.byType(CameraThumb), findsOneWidget);
    },
  );

  pickerTest(
    'foreground refresh revokes both permissions and restores library and preview',
    (tester) async {
      final picker = await mount(tester);
      picker.selection.toggle(_asset('0'));
      picker.setDisplayMode(DisplayMode.selected);
      await tester.pumpAndSettle();
      camera.cameraPermission = false;
      gallery.permissionState = XGalleryPermission.denied;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      expect(find.byType(CameraThumb), findsNothing);
      expect(find.byType(PickerGridItem), findsNothing);
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
      expect(find.byType(SelectedStrip), findsNothing);
      expect(find.text('1 selected'), findsNothing);
      expect(camera.disposeCalls, [1]);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      camera.cameraPermission = true;
      gallery.permissionState = XGalleryPermission.granted;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      expect(find.byType(CameraThumb), findsOneWidget);
      expect(_cell('0'), findsOneWidget);
      expect(picker.selection.count, 1);
      expect(find.byType(SelectedStrip), findsOneWidget);
      expect(camera.createCalls, hasLength(2));
      expect(gallery.permissionCalls, 3);
      picker.pop();
      await tester.pumpAndSettle();
      final queries = camera.cameraPermissionCalls;
      host.lifecycle.foreground();
      await tester.pump();
      expect(camera.cameraPermissionCalls, queries);
    },
  );

  pickerTest(
    'older permission and library completions cannot undo revocation',
    (tester) async {
      await mount(tester);
      final oldCamera = Completer<bool>();
      final oldPhotos = Completer<XGalleryPermission>();
      camera.queuedPermissions.add(oldCamera);
      gallery.queuedPermissions.add(oldPhotos);
      host.lifecycle.foreground();
      await tester.pump();
      camera.cameraPermission = false;
      gallery.permissionState = XGalleryPermission.denied;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      oldCamera.complete(true);
      oldPhotos.complete(XGalleryPermission.granted);
      await tester.pumpAndSettle();
      expect(find.byType(CameraThumb), findsNothing);
      expect(find.byType(PickerGridItem), findsNothing);
      expect(camera.createCalls, hasLength(1));

      gallery.permissionState = XGalleryPermission.granted;
      final oldAssets = Completer<List<XAsset>>();
      gallery.queuedAssets.add(oldAssets);
      gallery.emitLibraryChange();
      await tester.pump();
      gallery.permissionState = XGalleryPermission.denied;
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      oldAssets.complete([_asset('stale')]);
      await tester.pumpAndSettle();
      expect(_cell('stale'), findsNothing);
      expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
    },
  );

  pickerTest(
    'removal during camera initialization releases its late allocation',
    (tester) async {
      camera.initializeGate = Completer();
      final picker = await mount(tester);
      expect(camera.liveHandles, {1});
      picker.pop();
      await tester.pumpAndSettle();
      camera.initializeGate!.complete();
      await tester.pumpAndSettle();
      expect(camera.liveHandles, isEmpty);
      expect(camera.disposeCalls, [1]);
      expect(host.lifecycle.observed, isFalse);
    },
  );

  pickerTest(
    'permission queries completing after removal cannot create an owner',
    (tester) async {
      final cameraPermission = Completer<bool>();
      final photoPermission = Completer<XGalleryPermission>();
      camera.queuedPermissions.add(cameraPermission);
      gallery.queuedPermissions.add(photoPermission);
      final picker = await mount(tester);
      picker.pop();
      await tester.pumpAndSettle();
      cameraPermission.complete(true);
      photoPermission.complete(XGalleryPermission.granted);
      await tester.pumpAndSettle();
      expect(camera.createCalls, isEmpty);
      expect(host.lifecycle.observed, isFalse);
    },
  );

  pickerTest(
    'selection, album changes and the strip retain edits without a camera tile',
    (tester) async {
      final album = XAlbum(id: 'album', name: 'Album', count: 1);
      gallery = _Gallery(
        recents: [_asset('0'), _asset('1'), _asset('2')],
        albums: [album],
        assetsByAlbum: {
          'album': [_asset('other')],
        },
      );
      XGallery.backend = gallery;
      final picker = await mount(
        tester,
        page: MediaPickerPage(maxSelection: 2),
      );
      picker.selection.toggle(_asset('1'));
      picker.selection.toggle(_asset('0'));
      expect(picker.selection.toggle(_asset('2')), isFalse);
      await picker.selectAlbum(album);
      await tester.pumpAndSettle();
      expect(_cell('other'), findsOneWidget);
      expect(picker.selection.indexOf(_asset('1')), 1);
      expect(picker.selection.indexOf(_asset('0')), 2);
      picker.setDisplayMode(DisplayMode.selected);
      await tester.pumpAndSettle();
      expect(find.byType(CameraThumb).hitTestable(), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is PickerGridItem && w.viewKind == PickerViewKind.strip,
        ),
        findsNWidgets(2),
      );
      final composing = picker.handleAssetTap(_asset('1'));
      await tester.pumpAndSettle();
      final compose = host.pages.value.last as ComposePage;
      compose.focusedEntry.composerController.text = 'kept';
      await tester.runAsync(compose.focusedEntry.refreshPreviewForTest);
      final preview = compose.focusedEntry.renderedPreview;
      expect(preview, isNotNull);
      compose.pop();
      await tester.pumpAndSettle();
      await composing;
      final stripCell = find.byWidgetPredicate(
        (w) =>
            w is PickerGridItem &&
            w.asset.id == '1' &&
            w.viewKind == PickerViewKind.strip,
      );
      expect(
        tester
            .widget<RawImage>(
              find.descendant(of: stripCell, matching: find.byType(RawImage)),
            )
            .image,
        same(preview),
      );
      picker.setDisplayMode(DisplayMode.all);
      await picker.selectAlbum(null);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RawImage>(
              find.descendant(of: _cell('1'), matching: find.byType(RawImage)),
            )
            .image,
        same(preview),
      );
      final reopening = picker.handleAssetTap(_asset('1'));
      await tester.pumpAndSettle();
      expect(
        (host.pages.value.last as ComposePage).focusedEntry,
        same(compose.focusedEntry),
      );
      expect(
        (host.pages.value.last as ComposePage)
            .focusedEntry
            .composerController
            .text,
        'kept',
      );
      host.pages.value.last.pop();
      await tester.pumpAndSettle();
      await reopening;
    },
  );

  pickerTest(
    'capture opens the editor, submits once and animates the picker result dismissal',
    (tester) async {
      camera.picturePath = File('test/media/fixtures/capture.png')
          .absolute
          .path;
      final submitted = <List<ComposeResult>>[];
      final picker = await mount(
        tester,
        page: MediaPickerPage(
          filter: XAssetKind.image,
          composePurpose: ComposePurpose.avatar,
          onSubmit: (results) async {
            submitted.add(results);
            return ChatSendResult(cids: ['capture'], sourceForCid: (_) => null);
          },
        ),
      );
      final result = picker.future;
      picker.selection.toggle(_asset('0'));
      final controller = tester
          .widget<CameraThumb>(find.byType(CameraThumb))
          .controller
          .value;
      await tester.tap(find.byType(CameraThumb));
      await tester.pumpAndSettle();
      final page = host.pages.value.last as CameraPage;
      expect(page.session.value, same(controller));
      expect(page.filter, XAssetKind.image);
      expect(
        tester.widget<CameraButton>(find.byType(CameraButton)).onLongPress,
        isNull,
      );
      await picker.handleCameraTap();
      expect(host.pushed.whereType<CameraPage>(), hasLength(1));
      await tester.runAsync(
        tester.widget<CameraButton>(find.byType(CameraButton)).onPress!
            as Future<void> Function(),
      );
      await tester.pumpAndSettle();
      final compose = host.pages.value.last as ComposePage;
      expect(compose.purpose, ComposePurpose.avatar);
      expect(compose.assets, hasLength(1));
      expect(compose.assets.single, isA<ImageMedia>());
      expect(compose.onSubmit, same(picker.onSubmit));
      expect(picker.selection.count, 1);
      await tester.runAsync(compose.handleSubmit);
      await tester.pump();
      expect(picker.popped, isFalse);
      await tester.pumpAndSettle();
      final results = await result;
      expect(results, same(submitted.single));
      expect(results!.single.imageBytes, isNotEmpty);
      expect(picker.popped, isTrue);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(camera.takePictureCalls, hasLength(1));
      expect(camera.createCalls, hasLength(1));
      expect(camera.liveHandles, isEmpty);
    },
  );

  pickerTest(
    'camera and compose cancellation preserve selection and allow reopening',
    (tester) async {
      final picker = await mount(
        tester,
        page: MediaPickerPage(filter: XAssetKind.image),
      );
      picker.selection.toggle(_asset('0'));
      final opening = picker.handleCameraTap();
      await tester.pumpAndSettle();
      final first = host.pages.value.last as CameraPage;
      expect(first.filter, XAssetKind.image);
      expect(first.photo, isTrue);
      first.pop();
      await tester.pumpAndSettle();
      await opening;
      expect(picker.selection.count, 1);
      final next = picker.handleCameraTap();
      await tester.pumpAndSettle();
      final second = host.pages.value.last as CameraPage;
      second.pop(ImageMedia(file: File('test/media/fixtures/capture.png')));
      await tester.pumpAndSettle();
      final compose = host.pages.value.last as ComposePage;
      compose.handleCancel();
      await tester.pumpAndSettle();
      await next;
      expect(picker.selection.picked.map((a) => a.id), ['0']);
      expect(picker.popped, isFalse);
      expect(camera.createCalls, hasLength(1));
      expect(camera.disposeCalls, isEmpty);
    },
  );

  pickerTest(
    'picker disposal closes a loan and ignores its late capture result',
    (tester) async {
      final picker = await mount(tester);
      final opening = picker.handleCameraTap();
      await tester.pumpAndSettle();
      final page = host.pages.value.last as CameraPage;
      await tester.pumpWidget(const SizedBox());
      picker.dispose();
      expect(page.session.disposed, isTrue);
      picker.pop();
      await tester.pumpAndSettle();
      expect(page.session.disposed, isTrue);
      expect(camera.liveHandles, isEmpty);
      host.lifecycle.foreground();
      await tester.pumpAndSettle();
      page.pop(ImageMedia(file: File('test/media/fixtures/capture.png')));
      await tester.pumpAndSettle();
      await opening;
      expect(host.pushed.whereType<ComposePage>(), isEmpty);
      expect(camera.createCalls, hasLength(1));
      expect(camera.liveHandles, isEmpty);
    },
  );
}
