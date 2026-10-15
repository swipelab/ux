import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/testing.dart';
import 'package:ux/gallery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XGallery facade — method channel parsing', () {
    const channel = MethodChannel('ux/gallery');

    setUp(() {
      XGallery.backend = MethodChannelGalleryBackend();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('permission() parses the granted state', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'permission');
            return 'granted';
          });

      expect(await XGallery.permission(), XGalleryPermission.granted);
    });

    test('permission() falls back to denied on unknown values', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => 'mystery');

      expect(await XGallery.permission(), XGalleryPermission.denied);
    });

    test('albums() decodes a list of XAlbum', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'albums');
            expect((call.arguments as Map)['filter'], 'any');
            return [
              {
                'id': 'recents',
                'name': 'Recents',
                'count': 1234,
                'cover_kind': 'image',
              },
              {
                'id': 'videos',
                'name': 'Videos',
                'count': 12,
                'cover_kind': 'video',
              },
            ];
          });

      final albums = await XGallery.albums();
      expect(albums, hasLength(2));
      expect(albums[0].id, 'recents');
      expect(albums[0].count, 1234);
      expect(albums[0].coverKind, XAssetKind.image);
      expect(albums[1].coverKind, XAssetKind.video);
    });

    test('assets() decodes durations and timestamps', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'assets');
            final args = call.arguments as Map;
            expect(args['albumId'], 'recents');
            expect(args['filter'], 'video');
            expect(args['start'], 0);
            expect(args['end'], 60);
            return [
              {
                'id': 'a1',
                'kind': 'video',
                'duration_ms': 8500,
                'width': 1080,
                'height': 1920,
                'created_ms': 1700000000000,
              },
            ];
          });

      final assets = await XGallery.assets(
        albumId: 'recents',
        filter: XAssetKind.video,
        start: 0,
        end: 60,
      );
      expect(assets, hasLength(1));
      expect(assets.single.kind, XAssetKind.video);
      expect(assets.single.duration, const Duration(milliseconds: 8500));
      expect(assets.single.createdAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('thumbnail() returns the byte payload + dims', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'thumbnail');
            final args = call.arguments as Map;
            expect(args['assetId'], 'a1');
            expect(args['sizePx'], 381);
            return {
              'bytes': Uint8List.fromList([1, 2, 3]),
              'width': 381,
              'height': 254,
            };
          });

      final thumb = await XGallery.thumbnail('a1', sizePx: 381);
      expect(thumb.bytes, [1, 2, 3]);
      expect(thumb.width, 381);
      expect(thumb.height, 254);
    });

    test('saveToLibrary() encodes args and parses saved', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'saveToLibrary');
            final args = call.arguments as Map;
            expect(args['path'], '/tmp/clip.mp4');
            expect(args['kind'], 'video');
            expect(args['mime'], 'video/mp4');
            return 'saved';
          });

      final status = await XGallery.saveToLibrary(
        '/tmp/clip.mp4',
        kind: XAssetKind.video,
        mimeType: 'video/mp4',
      );
      expect(status, XGallerySaveStatus.saved);
    });

    test('saveToLibrary() omits mime when unset and parses denied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map;
            expect(args['kind'], 'image');
            expect(args.containsKey('mime'), isFalse);
            return 'denied';
          });

      final status = await XGallery.saveToLibrary(
        '/tmp/pic.jpg',
        kind: XAssetKind.image,
      );
      expect(status, XGallerySaveStatus.denied);
    });
  });

  group('FakeXGalleryBackend', () {
    test('requestPermission flips state to granted by default', () async {
      final fake = FakeXGalleryBackend(
        permissionState: XGalleryPermission.notDetermined,
      );
      XGallery.backend = fake;

      expect(await XGallery.permission(), XGalleryPermission.notDetermined);
      expect(await XGallery.requestPermission(), XGalleryPermission.granted);
      expect(await XGallery.permission(), XGalleryPermission.granted);
    });

    test('assets honours the (start, end) page window per album', () async {
      final pile = [
        for (var i = 0; i < 50; i++)
          XAsset(
            id: 'a$i',
            kind: XAssetKind.image,
            width: 100,
            height: 100,
            createdAt: DateTime.fromMillisecondsSinceEpoch(i * 1000),
          ),
      ];
      final fake = FakeXGalleryBackend(
        recents: pile,
        assetsByAlbum: {'all': pile},
      );
      XGallery.backend = fake;

      final firstPage = await XGallery.assets(start: 0, end: 10);
      expect(firstPage.map((a) => a.id), [for (var i = 0; i < 10; i++) 'a$i']);
      final tail = await XGallery.assets(albumId: 'all', start: 45, end: 999);
      expect(tail, hasLength(5));
      final past = await XGallery.assets(start: 200, end: 210);
      expect(past, isEmpty);
    });

    test('assets filters by kind when requested', () async {
      final mix = [
        XAsset(
          id: 'p',
          kind: XAssetKind.image,
          width: 1,
          height: 1,
          createdAt: DateTime(2024),
        ),
        XAsset(
          id: 'v',
          kind: XAssetKind.video,
          duration: const Duration(seconds: 3),
          width: 1,
          height: 1,
          createdAt: DateTime(2024),
        ),
      ];
      XGallery.backend = FakeXGalleryBackend(recents: mix);

      final justVideos = await XGallery.assets(
        filter: XAssetKind.video,
        start: 0,
        end: 10,
      );
      expect(justVideos.map((a) => a.id), ['v']);
    });

    test('saveToLibrary records paths and defaults to saved', () async {
      final fake = FakeXGalleryBackend();
      XGallery.backend = fake;

      final status = await XGallery.saveToLibrary(
        '/tmp/pic.jpg',
        kind: XAssetKind.image,
      );
      expect(status, XGallerySaveStatus.saved);
      expect(fake.savedToLibrary, ['/tmp/pic.jpg']);
    });

    test('saveToLibrary outcome is overridable via onSaveToLibrary', () async {
      XGallery.backend = FakeXGalleryBackend(
        onSaveToLibrary: (_, _) => XGallerySaveStatus.denied,
      );

      final status = await XGallery.saveToLibrary(
        '/tmp/pic.jpg',
        kind: XAssetKind.image,
      );
      expect(status, XGallerySaveStatus.denied);
    });
  });
}
