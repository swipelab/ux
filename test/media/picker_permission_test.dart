import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';
import 'package:ux/gallery.dart';
import 'package:ux/media.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';

import 'camera_test_backend.dart';
import 'fake_host.dart';

class _Host extends FakeMediaHost {
  @override
  String get cameraAccessRationale =>
      'Take photos and videos with your camera.';
  @override
  String get photoAccessTitle => 'Access Your Photos';
  @override
  String get allowPhotoAccess => 'Allow Photos';
  @override
  String get openSettings => 'Go to Settings';
  @override
  String get limitedPhotosRationale => 'Only your selected photos appear here.';
  @override
  String get manage => 'Manage';

  @override
  TextStyle get body =>
      TextStyle(fontFamily: family, fontSize: 16, height: 1.25);
}

class _Home with Screen<void> {
  @override
  Widget buildPresenter(BuildContext context) => const SizedBox.expand();
}

Future<void> _loadFonts() async {
  final config = File('.dart_tool/package_config.json');
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  Uri root(String name) => config.absolute.uri.resolve(
    '${packages.cast<Map>().singleWhere((p) => p['name'] == name)['rootUri']}/',
  );
  final flutter = root('flutter');
  final roboto = FontLoader('Roboto');
  for (final weight in ['Regular', 'Bold']) {
    roboto.addFont(
      File.fromUri(
        flutter.resolve(
          '../../bin/cache/artifacts/material_fonts/Roboto-$weight.ttf',
        ),
      ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
    );
  }
  await roboto.load();
  final icons = root('cupertino_icons').resolve('assets/CupertinoIcons.ttf');
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')
        ..addFont(File.fromUri(icons).readAsBytes().then(ByteData.sublistView)))
      .load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  for (final (name, photos, hasCamera) in [
    ('camera_denied', XGalleryPermission.granted, false),
    ('photos_denied', XGalleryPermission.denied, true),
    ('both_denied', XGalleryPermission.denied, false),
    ('photos_limited', XGalleryPermission.limited, true),
    ('all_granted', XGalleryPermission.granted, true),
  ]) {
    testWidgets('phone permission state: $name', (tester) async {
      final host = _Host();
      MediaHost.current = host;
      final originalGallery = XGallery.backend;
      final originalCamera = XCameraBackend.instance;
      final camera = CameraTestBackend()..cameraPermission = hasCamera;
      XCameraBackend.instance = camera;
      final thumbnailBytes = File('test/media/fixtures/capture.png')
          .readAsBytesSync();
      XGallery.backend = FakeXGalleryBackend(
        permissionState: photos,
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
            XAssetThumbnail(bytes: thumbnailBytes, width: 12, height: 8),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      final picker = MediaPickerPage()..onPush();
      try {
        await tester.pumpWidget(
          CupertinoApp(
            debugShowCheckedModeBanner: false,
            theme: const CupertinoThemeData(
              brightness: Brightness.dark,
              textTheme: CupertinoTextThemeData(
                textStyle: TextStyle(fontFamily: 'Roboto'),
              ),
            ),
            home: ScreenStack(home: _Home(), stack: [picker]),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => precacheImage(
            MemoryImage(thumbnailBytes),
            tester.element(find.byType(CupertinoApp)),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(CupertinoApp),
          matchesGoldenFile('goldens/picker_permission_$name.png'),
        );
        final hasPhotos =
            photos == XGalleryPermission.granted ||
            photos == XGalleryPermission.limited;
        if (!hasPhotos) {
          expect(find.byType(PickerPermissionPlaceholder), findsOneWidget);
          expect(find.byType(CameraThumb), findsNothing);
          expect(find.byType(PickerCameraBanner), findsNothing);
          expect(find.byType(SliverGrid), findsNothing);
          expect(find.text(host.photoAccessTitle), findsOneWidget);
          expect(find.text(host.openSettings), findsOneWidget);
          expect(find.text('Recents'), findsNothing);
          final title = tester.getRect(find.text(host.photoAccessTitle));
          final button = find
              .ancestor(
                of: find.text(host.openSettings),
                matching: find.byType(Container),
              )
              .first;
          expect(tester.getRect(button).top - title.bottom, 32);
          expect(
            tester.widget<Container>(button).padding,
            const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
          );
          final content = find
              .ancestor(
                of: find.text(host.photoAccessTitle),
                matching: find.byType(Column),
              )
              .first;
          expect(
            tester.getCenter(content),
            tester.getCenter(find.byType(PickerPermissionPlaceholder)),
          );
        } else if (!hasCamera) {
          final banner = find.byType(PickerCameraBanner);
          expect(banner, findsOneWidget);
          final rationale = find.text(host.cameraAccessRationale);
          expect(rationale, findsOneWidget);
          expect(
            tester.getTopLeft(rationale).dx - tester.getTopLeft(banner).dx,
            16,
          );
          final button = find.text(host.manage);
          expect(button, findsOneWidget);
          expect(
            tester.widget<Text>(rationale).style,
            host.body.copyWith(color: host.textSecondary),
          );
          final pill = find
              .ancestor(of: button, matching: find.byType(Container))
              .first;
          expect(
            tester.widget<Container>(pill).padding,
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          );
          expect(tester.getRect(banner).right - tester.getRect(pill).right, 16);
          expect(
            tester.getRect(banner).bottom - tester.getRect(pill).bottom,
            greaterThanOrEqualTo(12),
          );
        } else {
          expect(find.byType(CameraThumb), findsOneWidget);
          expect(find.byType(PickerCameraBanner), findsNothing);
          expect(find.byType(PickerPermissionPlaceholder), findsNothing);
          if (photos == XGalleryPermission.limited) {
            expect(find.text(host.limitedPhotosRationale), findsOneWidget);
            expect(find.text(host.manage), findsOneWidget);
          }
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        picker.dispose();
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(camera.liveHandles, isEmpty);
        host.lifecycle.dispose();
        XGallery.backend = originalGallery;
        XCameraBackend.instance = originalCamera;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }
}
