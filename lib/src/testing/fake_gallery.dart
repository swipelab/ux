import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:ux/src/gallery.dart';

/// 1×1 transparent PNG. Decodable by `Image.memory`, so tests that
/// mount the picker UI against [FakeXGalleryBackend] don't need to
/// provide their own thumbnail bytes.
final Uint8List _placeholderPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// In-memory backend for [XGallery] tests. Swap in via
/// `XGallery.backend = FakeXGalleryBackend(...)` before any UI
/// mounts; restore with `XGallery.backend = ...` (or by replacing
/// with another fake) in `tearDown`.
class FakeXGalleryBackend implements XGalleryBackend {
  FakeXGalleryBackend({
    this.permissionState = XGalleryPermission.granted,
    List<XAlbum> albums = const [],
    Map<String, List<XAsset>> assetsByAlbum = const {},
    List<XAsset> recents = const [],
    this.onRequestPermission,
    this.onOpenSettings,
    this.onPresentLimitedLibraryPicker,
    this.onSaveToLibrary,
    XAssetThumbnail Function(String assetId, int sizePx)? thumbnailFor,
    io.File Function(String assetId)? fileFor,
  })  : _albums = List.unmodifiable(albums),
        _assetsByAlbum = Map.unmodifiable(
          assetsByAlbum.map(
            (k, v) => MapEntry(k, List<XAsset>.unmodifiable(v)),
          ),
        ),
        _recents = List.unmodifiable(recents),
        _thumbnailFor = thumbnailFor ?? _defaultThumbnail,
        _fileFor = fileFor ?? _defaultFile;

  /// Mutable so tests can simulate user grant after `requestPermission`.
  XGalleryPermission permissionState;

  final List<XAlbum> _albums;
  final Map<String, List<XAsset>> _assetsByAlbum;
  final List<XAsset> _recents;
  final XAssetThumbnail Function(String assetId, int sizePx) _thumbnailFor;
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
  /// `permissionState` to [XGalleryPermission.granted].
  final XGalleryPermission Function()? onRequestPermission;
  final void Function()? onOpenSettings;
  final void Function()? onPresentLimitedLibraryPicker;

  /// Optional hook deciding [saveToLibrary]'s outcome; defaults to
  /// [XGallerySaveStatus.saved].
  final XGallerySaveStatus Function(String path, XAssetKind kind)?
      onSaveToLibrary;

  /// Paths handed to [saveToLibrary], in call order.
  final List<String> savedToLibrary = [];

  static XAssetThumbnail _defaultThumbnail(String _, int sizePx) =>
      XAssetThumbnail(
        bytes: _placeholderPng,
        width: sizePx,
        height: sizePx,
      );

  static io.File _defaultFile(String assetId) => io.File('/dev/null/$assetId');

  @override
  Future<XGalleryPermission> permission() async => permissionState;

  @override
  Future<XGalleryPermission> requestPermission() async {
    permissionState = onRequestPermission?.call() ?? XGalleryPermission.granted;
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
  Future<List<XAlbum>> albums({XAssetKind? filter}) async {
    if (filter == null) return _albums;
    return [
      for (final a in _albums)
        if (a.coverKind == null || a.coverKind == filter) a,
    ];
  }

  @override
  Future<List<XAsset>> assets({
    String? albumId,
    XAssetKind? filter,
    required int start,
    required int end,
  }) async {
    final source = albumId == null
        ? _recents
        : _assetsByAlbum[albumId] ?? const <XAsset>[];
    final filtered = filter == null
        ? source
        : [
            for (final a in source)
              if (a.kind == filter) a
          ];
    if (start >= filtered.length) return const [];
    return filtered.sublist(start, end.clamp(start, filtered.length));
  }

  @override
  Future<XAssetThumbnail> thumbnail(
    String assetId, {
    required int sizePx,
  }) async =>
      _thumbnailFor(assetId, sizePx);

  @override
  Future<io.File> resolveFile(String assetId) async => _fileFor(assetId);

  @override
  Future<XGallerySaveStatus> saveToLibrary(
    String path, {
    required XAssetKind kind,
    String? mimeType,
  }) async {
    savedToLibrary.add(path);
    return onSaveToLibrary?.call(path, kind) ?? XGallerySaveStatus.saved;
  }
}
