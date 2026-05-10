import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UxGallery facade — method channel parsing', () {
    const channel = MethodChannel('ux/gallery');

    setUp(() {
      UxGallery.backend = MethodChannelGalleryBackend();
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

      expect(await UxGallery.permission(), UxGalleryPermission.granted);
    });

    test('permission() falls back to denied on unknown values', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => 'mystery');

      expect(await UxGallery.permission(), UxGalleryPermission.denied);
    });

    test('albums() decodes a list of UxAlbum', () async {
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

      final albums = await UxGallery.albums();
      expect(albums, hasLength(2));
      expect(albums[0].id, 'recents');
      expect(albums[0].count, 1234);
      expect(albums[0].coverKind, UxAssetKind.image);
      expect(albums[1].coverKind, UxAssetKind.video);
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

      final assets = await UxGallery.assets(
        albumId: 'recents',
        filter: UxAssetKind.video,
        start: 0,
        end: 60,
      );
      expect(assets, hasLength(1));
      expect(assets.single.kind, UxAssetKind.video);
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

      final thumb = await UxGallery.thumbnail('a1', sizePx: 381);
      expect(thumb.bytes, [1, 2, 3]);
      expect(thumb.width, 381);
      expect(thumb.height, 254);
    });
  });

  group('FakeUxGalleryBackend', () {
    test('requestPermission flips state to granted by default', () async {
      final fake = FakeUxGalleryBackend(
        permissionState: UxGalleryPermission.notDetermined,
      );
      UxGallery.backend = fake;

      expect(await UxGallery.permission(),
          UxGalleryPermission.notDetermined);
      expect(await UxGallery.requestPermission(),
          UxGalleryPermission.granted);
      expect(await UxGallery.permission(), UxGalleryPermission.granted);
    });

    test('assets honours the (start, end) page window per album', () async {
      final pile = [
        for (var i = 0; i < 50; i++)
          UxAsset(
            id: 'a$i',
            kind: UxAssetKind.image,
            width: 100,
            height: 100,
            createdAt: DateTime.fromMillisecondsSinceEpoch(i * 1000),
          ),
      ];
      final fake = FakeUxGalleryBackend(
        recents: pile,
        assetsByAlbum: {'all': pile},
      );
      UxGallery.backend = fake;

      final firstPage = await UxGallery.assets(start: 0, end: 10);
      expect(firstPage.map((a) => a.id), [
        for (var i = 0; i < 10; i++) 'a$i',
      ]);
      final tail = await UxGallery.assets(albumId: 'all', start: 45, end: 999);
      expect(tail, hasLength(5));
      final past = await UxGallery.assets(start: 200, end: 210);
      expect(past, isEmpty);
    });

    test('assets filters by kind when requested', () async {
      final mix = [
        UxAsset(
          id: 'p',
          kind: UxAssetKind.image,
          width: 1,
          height: 1,
          createdAt: DateTime(2024),
        ),
        UxAsset(
          id: 'v',
          kind: UxAssetKind.video,
          duration: const Duration(seconds: 3),
          width: 1,
          height: 1,
          createdAt: DateTime(2024),
        ),
      ];
      UxGallery.backend = FakeUxGalleryBackend(recents: mix);

      final justVideos = await UxGallery.assets(
        filter: UxAssetKind.video,
        start: 0,
        end: 10,
      );
      expect(justVideos.map((a) => a.id), ['v']);
    });
  });
}
