import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:ux/src/gallery.dart';

/// 1×1 transparent PNG. Decodable by `Image.memory`, so tests that
/// mount the picker UI against [FakeUxGalleryBackend] don't need to
/// provide their own thumbnail bytes.
final Uint8List _placeholderPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// In-memory backend for [UxGallery] tests. Swap in via
/// `UxGallery.backend = FakeUxGalleryBackend(...)` before any UI
/// mounts; restore with `UxGallery.backend = ...` (or by replacing
/// with another fake) in `tearDown`.
class FakeUxGalleryBackend implements UxGalleryBackend {
  FakeUxGalleryBackend({
    this.permissionState = UxGalleryPermission.granted,
    List<UxAlbum> albums = const [],
    Map<String, List<UxAsset>> assetsByAlbum = const {},
    List<UxAsset> recents = const [],
    this.onRequestPermission,
    this.onOpenSettings,
    this.onPresentLimitedLibraryPicker,
    UxAssetThumbnail Function(String assetId, int sizePx)? thumbnailFor,
    io.File Function(String assetId)? fileFor,
  })  : _albums = List.unmodifiable(albums),
        _assetsByAlbum = Map.unmodifiable(
          assetsByAlbum.map(
            (k, v) => MapEntry(k, List<UxAsset>.unmodifiable(v)),
          ),
        ),
        _recents = List.unmodifiable(recents),
        _thumbnailFor = thumbnailFor ?? _defaultThumbnail,
        _fileFor = fileFor ?? _defaultFile;

  /// Mutable so tests can simulate user grant after `requestPermission`.
  UxGalleryPermission permissionState;

  final List<UxAlbum> _albums;
  final Map<String, List<UxAsset>> _assetsByAlbum;
  final List<UxAsset> _recents;
  final UxAssetThumbnail Function(String assetId, int sizePx) _thumbnailFor;
  final io.File Function(String assetId) _fileFor;

  final StreamController<void> _libraryChanges =
      StreamController<void>.broadcast();

  /// Tests call this to simulate the platform `photoLibraryDidChange`
  /// event — drives any reactive reload wiring without going through
  /// the real method channel.
  void emitLibraryChange() => _libraryChanges.add(null);

  @override
  Stream<void> get libraryChanges => _libraryChanges.stream;

  /// Optional hook fired on `requestPermission`. Default updates
  /// `permissionState` to [UxGalleryPermission.granted].
  final UxGalleryPermission Function()? onRequestPermission;
  final void Function()? onOpenSettings;
  final void Function()? onPresentLimitedLibraryPicker;

  static UxAssetThumbnail _defaultThumbnail(String _, int sizePx) =>
      UxAssetThumbnail(
        bytes: _placeholderPng,
        width: sizePx,
        height: sizePx,
      );

  static io.File _defaultFile(String assetId) =>
      io.File('/dev/null/$assetId');

  @override
  Future<UxGalleryPermission> permission() async => permissionState;

  @override
  Future<UxGalleryPermission> requestPermission() async {
    permissionState =
        onRequestPermission?.call() ?? UxGalleryPermission.granted;
    return permissionState;
  }

  @override
  Future<void> openSettings() async {
    onOpenSettings?.call();
  }

  @override
  Future<void> presentLimitedLibraryPicker() async {
    onPresentLimitedLibraryPicker?.call();
  }

  @override
  Future<List<UxAlbum>> albums({UxAssetKind? filter}) async {
    if (filter == null) return _albums;
    return [
      for (final a in _albums)
        if (a.coverKind == null || a.coverKind == filter) a,
    ];
  }

  @override
  Future<List<UxAsset>> assets({
    String? albumId,
    UxAssetKind? filter,
    required int start,
    required int end,
  }) async {
    final source = albumId == null
        ? _recents
        : _assetsByAlbum[albumId] ?? const <UxAsset>[];
    final filtered = filter == null
        ? source
        : [for (final a in source) if (a.kind == filter) a];
    if (start >= filtered.length) return const [];
    return filtered.sublist(start, end.clamp(start, filtered.length));
  }

  @override
  Future<UxAssetThumbnail> thumbnail(
    String assetId, {
    required int sizePx,
  }) async =>
      _thumbnailFor(assetId, sizePx);

  @override
  Future<io.File> resolveFile(String assetId) async => _fileFor(assetId);
}
