import 'package:ux/gallery.dart';

/// In-memory LRU of [XAssetThumbnail]s keyed by `(assetId, sizePx)`.
/// Telegram's `PHCachingImageManager` already caches on the native
/// side; this Dart-side LRU keeps repeated rebuilds (scroll
/// off-screen → back on) from re-encoding.
class ThumbnailCache {
  /// Creates a cache of [capacity] thumbnails.
  ThumbnailCache({this.capacity = 200});

  /// Thumbnails kept before the least recently used is dropped.
  final int capacity;
  final Map<String, XAssetThumbnail> _entries = <String, XAssetThumbnail>{};
  final Map<String, Future<XAssetThumbnail>> _inflight =
      <String, Future<XAssetThumbnail>>{};

  /// Asset IDs whose selection-ring entry spring (scale 0.2 → 1.0 +
  /// alpha) has already played in this picker session. Mirrors
  /// telegram-iOS's `if self.checkNode == nil` gate on
  /// `MediaPickerGridItem.swift:261` — the spring runs once per
  /// asset, not once per cell mount, so a tile that scrolls out of
  /// the GridView's cache and back doesn't replay it.
  final Set<String> ringSpringPlayed = <String>{};

  String _key(String assetId, int sizePx) => '$assetId|$sizePx';

  /// The cached thumbnail, marked as just used; absent on a miss.
  XAssetThumbnail? peek(String assetId, int sizePx) {
    final k = _key(assetId, sizePx);
    final hit = _entries.remove(k);
    if (hit == null) return null;
    _entries[k] = hit;
    return hit;
  }

  /// Fetch (cache hit, in-flight share, or new request). Repeated
  /// calls for the same key while the future is in flight share the
  /// same future so we don't hit the platform channel twice.
  Future<XAssetThumbnail> load(String assetId, {required int sizePx}) {
    final k = _key(assetId, sizePx);
    final cached = peek(assetId, sizePx);
    if (cached != null) return Future<XAssetThumbnail>.value(cached);
    final pending = _inflight[k];
    if (pending != null) return pending;
    final future = XGallery.thumbnail(assetId, sizePx: sizePx).then(
      (thumb) {
        _entries[k] = thumb;
        if (_entries.length > capacity) _entries.remove(_entries.keys.first);
        _inflight.remove(k);
        return thumb;
      },
      onError: (Object err, StackTrace st) {
        _inflight.remove(k);
        throw err;
      },
    );
    _inflight[k] = future;
    return future;
  }

  /// Drops every thumbnail, pending load and played ring.
  void clear() {
    _entries.clear();
    _inflight.clear();
    ringSpringPlayed.clear();
  }
}
