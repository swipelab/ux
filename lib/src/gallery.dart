import 'dart:io' as io;

import 'package:flutter/services.dart';

/// Authorisation state of the system photo library.
///
/// Mirrors the union of `PHAuthorizationStatus` (iOS / macOS) and
/// Android's manifest-permission outcomes:
/// - [notDetermined] — never asked. Prompt the user with
///   [XGallery.requestPermission].
/// - [denied] — user said no. [XGallery.openSettings] is the only
///   way back.
/// - [restricted] — parental controls / MDM. Same UI as [denied].
/// - [limited] — iOS 14+. User picked a subset; the grid still
///   populates from that subset. Call
///   [XGallery.presentLimitedLibraryPicker] to let them adjust.
/// - [granted] — full access.
enum XGalleryPermission { notDetermined, denied, restricted, limited, granted }

enum XAssetKind { image, video }

/// A user-visible album / collection in the system photo library
/// (`PHAssetCollection` on Apple, `MediaStore.Bucket` on Android).
class XAlbum {
  const XAlbum({
    required this.id,
    required this.name,
    required this.count,
    this.coverKind,
  });

  final String id;
  final String name;
  final int count;
  final XAssetKind? coverKind;
}

/// A single asset (photo or video) in the system library
/// (`PHAsset` / `ContentResolver` row).
class XAsset {
  const XAsset({
    required this.id,
    required this.kind,
    this.duration,
    required this.width,
    required this.height,
    required this.createdAt,
  });

  /// Stable identifier (e.g. iOS `localIdentifier`, Android `content://` URI).
  final String id;
  final XAssetKind kind;

  /// Duration for videos; null for photos.
  final Duration? duration;
  final int width;
  final int height;
  final DateTime createdAt;
}

/// Cell-sized thumbnail bytes ready for `Image.memory`. Backed by
/// `PHCachingImageManager` on Apple and `MediaStore.Thumbnails` on
/// Android.
class XAssetThumbnail {
  const XAssetThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// Backend contract that [XGallery] dispatches into. The default
/// implementation calls into native code via the `ux/gallery` method
/// channel; tests substitute their own (see
/// `ux/lib/testing.dart`'s `FakeXGalleryBackend`).
abstract class XGalleryBackend {
  Future<XGalleryPermission> permission();
  Future<XGalleryPermission> requestPermission();
  Future<void> openSettings();
  Future<void> presentLimitedLibraryPicker();
  Future<List<XAlbum>> albums({XAssetKind? filter});
  Future<List<XAsset>> assets({
    String? albumId,
    XAssetKind? filter,
    required int start,
    required int end,
  });
  Future<XAssetThumbnail> thumbnail(String assetId, {required int sizePx});
  Future<io.File> resolveFile(String assetId);

  /// Emits whenever the underlying photo library reports a change —
  /// limited-subset edits via `presentLimitedLibraryPicker`, external
  /// edits from Photos.app, or permission flips from Settings.
  /// Subscribers should re-fetch any cached album / asset listings on
  /// each event.
  Stream<void> get libraryChanges;
}

/// Static facade for the system photo library. All state lives in the
/// platform; this class is a thin Dart-side wrapper that dispatches
/// into [backend].
class XGallery {
  XGallery._();

  /// Swap to inject a fake (e.g.
  /// `FakeXGalleryBackend` from `package:ux/testing.dart`) before
  /// any UI code mounts.
  static XGalleryBackend backend = MethodChannelGalleryBackend();

  static Future<XGalleryPermission> permission() => backend.permission();

  static Future<XGalleryPermission> requestPermission() =>
      backend.requestPermission();

  static Future<void> openSettings() => backend.openSettings();

  /// iOS 14+ only — opens the system "manage limited access" sheet.
  /// No-op on Android / older iOS.
  static Future<void> presentLimitedLibraryPicker() =>
      backend.presentLimitedLibraryPicker();

  /// Albums in the user's library, ordered Recents → smart → user.
  /// Pass [filter] to restrict to image-only / video-only albums.
  static Future<List<XAlbum>> albums({XAssetKind? filter}) =>
      backend.albums(filter: filter);

  /// Paginate assets within [albumId] (or all assets if null), sorted
  /// by `createdAt DESC`. [start] inclusive, [end] exclusive.
  static Future<List<XAsset>> assets({
    String? albumId,
    XAssetKind? filter,
    required int start,
    required int end,
  }) =>
      backend.assets(
        albumId: albumId,
        filter: filter,
        start: start,
        end: end,
      );

  /// Cell-sized thumbnail at `~max(width,height) <= sizePx`. Native
  /// caches keep repeated calls cheap; the caller still maintains a
  /// small Dart-side LRU keyed by `(assetId, sizePx)`.
  static Future<XAssetThumbnail> thumbnail(
    String assetId, {
    required int sizePx,
  }) =>
      backend.thumbnail(assetId, sizePx: sizePx);

  /// Resolve a real `io.File` for the asset. Photo / video alike.
  /// On Android, this stream-copies a `content://` source into the
  /// app cache (since `dart:io` can't read content URIs directly).
  static Future<io.File> resolveFile(String assetId) =>
      backend.resolveFile(assetId);

  /// Emits whenever the system photo library changes — limited-subset
  /// edits, external edits, permission changes. Picker UIs subscribe
  /// to reload their cached asset list reactively.
  static Stream<void> get libraryChanges => backend.libraryChanges;
}

/// Default [XGalleryBackend] — dispatches to native code via the
/// `ux/gallery` method channel. Public so test code can reinstall it
/// after swapping to a fake.
class MethodChannelGalleryBackend implements XGalleryBackend {
  static const _channel = MethodChannel('ux/gallery');
  static const _changesChannel = EventChannel('ux/gallery/changes');

  /// Lazy broadcast view of `ux/gallery/changes`. The native side only
  /// holds a single sink; a broadcast Stream lets multiple Dart
  /// listeners (e.g. picker + selected-strip) subscribe independently.
  @override
  late final Stream<void> libraryChanges =
      _changesChannel.receiveBroadcastStream().map((_) {});

  static String _kindArg(XAssetKind? k) => switch (k) {
        null => 'any',
        XAssetKind.image => 'image',
        XAssetKind.video => 'video',
      };

  static XGalleryPermission _parsePermission(String? name) =>
      switch (name) {
        'notDetermined' => XGalleryPermission.notDetermined,
        'denied' => XGalleryPermission.denied,
        'restricted' => XGalleryPermission.restricted,
        'limited' => XGalleryPermission.limited,
        'granted' => XGalleryPermission.granted,
        _ => XGalleryPermission.denied,
      };

  static XAssetKind _parseKind(Object? v) =>
      v == 'video' ? XAssetKind.video : XAssetKind.image;

  static XAsset _parseAsset(Map<Object?, Object?> m) => XAsset(
        id: m['id']! as String,
        kind: _parseKind(m['kind']),
        duration: m['duration_ms'] != null
            ? Duration(milliseconds: (m['duration_ms']! as num).toInt())
            : null,
        width: (m['width']! as num).toInt(),
        height: (m['height']! as num).toInt(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (m['created_ms']! as num).toInt(),
        ),
      );

  static XAlbum _parseAlbum(Map<Object?, Object?> m) => XAlbum(
        id: m['id']! as String,
        name: m['name']! as String,
        count: (m['count']! as num).toInt(),
        coverKind: m['cover_kind'] == null ? null : _parseKind(m['cover_kind']),
      );

  @override
  Future<XGalleryPermission> permission() async {
    final s = await _channel.invokeMethod<String>('permission');
    return _parsePermission(s);
  }

  @override
  Future<XGalleryPermission> requestPermission() async {
    final s = await _channel.invokeMethod<String>('requestPermission');
    return _parsePermission(s);
  }

  @override
  Future<void> openSettings() async {
    await _channel.invokeMethod<void>('openSettings');
  }

  @override
  Future<void> presentLimitedLibraryPicker() async {
    await _channel.invokeMethod<void>('presentLimitedLibraryPicker');
  }

  @override
  Future<List<XAlbum>> albums({XAssetKind? filter}) async {
    final list = await _channel.invokeMethod<List<Object?>>(
      'albums',
      {'filter': _kindArg(filter)},
    );
    if (list == null) return const [];
    return [
      for (final raw in list) _parseAlbum((raw! as Map).cast()),
    ];
  }

  @override
  Future<List<XAsset>> assets({
    String? albumId,
    XAssetKind? filter,
    required int start,
    required int end,
  }) async {
    final list = await _channel.invokeMethod<List<Object?>>(
      'assets',
      {
        'albumId': albumId,
        'filter': _kindArg(filter),
        'start': start,
        'end': end,
      },
    );
    if (list == null) return const [];
    return [
      for (final raw in list) _parseAsset((raw! as Map).cast()),
    ];
  }

  @override
  Future<XAssetThumbnail> thumbnail(
    String assetId, {
    required int sizePx,
  }) async {
    final m = await _channel.invokeMethod<Map<Object?, Object?>>(
      'thumbnail',
      {'assetId': assetId, 'sizePx': sizePx},
    );
    return XAssetThumbnail(
      bytes: m!['bytes']! as Uint8List,
      width: (m['width']! as num).toInt(),
      height: (m['height']! as num).toInt(),
    );
  }

  @override
  Future<io.File> resolveFile(String assetId) async {
    final path = await _channel.invokeMethod<String>(
      'resolveFile',
      {'assetId': assetId},
    );
    return io.File(path!);
  }
}
