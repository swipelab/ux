import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'package:ux/src/screen/x_screen_sources.dart';

/// Production [XScreenSourcesBackend]: `ux/screen_sources` for commands.
class MethodChannelXScreenSourcesBackend implements XScreenSourcesBackend {
  /// Creates a backend bound to the `ux/screen_sources` channel.
  MethodChannelXScreenSourcesBackend();

  static const _channel = MethodChannel('ux/screen_sources');

  static const _maxThumbnailEdge = 4096;

  static const _sourceKeys = {
    'id',
    'kind',
    'title',
    'applicationName',
    'sourceWidth',
    'sourceHeight',
    'thumbnailPng',
  };

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<bool> available() => _bool('available');

  @override
  Future<bool> hasPermission() => _bool('hasPermission');

  @override
  Future<bool> requestPermission() => _bool('requestPermission');

  @override
  Future<List<XScreenSource>> list({
    required Set<String> allowedDisplayIds,
    required Set<String> allowedWindowIds,
    int thumbnailWidth = 320,
    int thumbnailHeight = 180,
  }) async {
    _requireSupported();
    _requireEdge(thumbnailWidth, 'thumbnailWidth');
    _requireEdge(thumbnailHeight, 'thumbnailHeight');
    final raw = await _invoke<List<Object?>>('list', {
      'allowedDisplayIds': allowedDisplayIds.toList(growable: false),
      'allowedWindowIds': allowedWindowIds.toList(growable: false),
      'thumbnailWidth': thumbnailWidth,
      'thumbnailHeight': thumbnailHeight,
    });
    return raw.map(_decodeSource).toList(growable: false);
  }

  Future<bool> _bool(String method) async {
    _requireSupported();
    return _invoke<bool>(method);
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (e) {
      throw XScreenSourcesException(e.code, e.message);
    }
    if (result is! T) {
      throw _invalid('result', 'expected $T, got ${result.runtimeType}');
    }
    return result;
  }

  void _requireSupported() {
    if (supported) return;
    throw XScreenSourcesException('unsupported', '$defaultTargetPlatform');
  }

  static void _requireEdge(int value, String name) {
    if (value > 0 && value <= _maxThumbnailEdge) return;
    throw ArgumentError.value(value, name, 'must be 1..$_maxThumbnailEdge');
  }

  static XScreenSource _decodeSource(Object? raw) {
    if (raw is! Map) {
      throw _invalid('source', 'expected a map, got ${raw.runtimeType}');
    }
    final m = raw.cast<Object?, Object?>();
    for (final key in _sourceKeys) {
      if (!m.containsKey(key)) throw _invalid(key, 'missing');
    }
    for (final key in m.keys) {
      if (!_sourceKeys.contains(key)) throw _invalid('$key', 'unknown key');
    }

    final id = m['id'];
    if (id is! String) throw _invalid('id', 'expected String, got $id');
    final title = m['title'];
    if (title is! String) {
      throw _invalid('title', 'expected String, got $title');
    }
    final applicationName = m['applicationName'];
    if (applicationName is! String?) {
      throw _invalid(
          'applicationName', 'expected String?, got $applicationName');
    }
    final sourceWidth = m['sourceWidth'];
    if (sourceWidth is! int) {
      throw _invalid('sourceWidth', 'expected int, got $sourceWidth');
    }
    final sourceHeight = m['sourceHeight'];
    if (sourceHeight is! int) {
      throw _invalid('sourceHeight', 'expected int, got $sourceHeight');
    }
    final thumbnailPng = m['thumbnailPng'];
    if (thumbnailPng is! Uint8List?) {
      throw _invalid('thumbnailPng', 'expected Uint8List?, got $thumbnailPng');
    }

    return XScreenSource(
      id: id,
      kind: switch (m['kind']) {
        'display' => XScreenSourceKind.display,
        'window' => XScreenSourceKind.window,
        final other => throw _invalid('kind', 'expected a kind, got $other'),
      },
      title: title,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      thumbnailPng: thumbnailPng,
      applicationName: applicationName,
    );
  }

  static XScreenSourcesException _invalid(Object? field, String detail) =>
      XScreenSourcesException('invalid_response', '$field: $detail');
}
