import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ux/src/_ffi.dart';

/// Native URL / phone / email detection plus an OS-handler launcher.
class UxUrl {
  UxUrl._();

  static const _channel = MethodChannel('ux/url');

  /// Returns ranges of detected URLs / emails / phone numbers in [text],
  /// sorted by [UrlMatch.start] ascending and non-overlapping. Offsets
  /// are UTF-16 code units. Empty / no-sigil inputs and missing native
  /// symbols resolve to `const []`.
  static List<UrlMatch> match(String text) {
    if (text.isEmpty) return const [];
    if (!_hasSigil(text)) return const [];
    final detect = _matchUrl;
    final free = _free;
    if (detect == null || free == null) return const [];

    final inPtr = text.toNativeUtf16();
    final sizePtr = calloc<Int32>();
    Pointer<Uint8> out = nullptr;
    try {
      out = detect(inPtr.cast<Uint16>(), text.length, sizePtr);
      final size = sizePtr.value;
      if (out == nullptr || size <= 0) return const [];
      return _decode(out.asTypedList(size));
    } finally {
      calloc.free(inPtr);
      calloc.free(sizePtr);
      if (out != nullptr) free(out);
    }
  }

  /// Opens [url] via the OS handler. Returns false on channel error or
  /// when no handler can resolve the scheme.
  ///
  /// Scheme is gated against a fixed allowlist. Schemes like `intent://`,
  /// `file://`, `javascript:`, `data:`, or USSD-bearing `tel:*…#` are
  /// rejected before reaching the OS dispatcher — message text is
  /// sender-controlled and the OS will happily launch privileged or
  /// destructive URIs otherwise.
  static Future<bool> launch(String url) async {
    if (kIsWeb) return false;
    if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) {
      return false;
    }
    if (!_isLaunchable(url)) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('launch', {'url': url});
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

const Set<String> _kLaunchSchemes = {
  'http', 'https',
  'mailto', 'tel', 'sms',
  'banlu', 'tg',
};

bool _isLaunchable(String url) {
  final colon = url.indexOf(':');
  if (colon <= 0) return false;
  final scheme = url.substring(0, colon).toLowerCase();
  if (!_kLaunchSchemes.contains(scheme)) return false;
  // Bidi controls let a sender visually reverse the displayed URL while
  // the byte order — what the OS opens — points elsewhere. Reject any
  // URL containing them rather than guessing the user's intent.
  for (int i = 0; i < url.length; i++) {
    final c = url.codeUnitAt(i);
    if ((c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)) {
      return false;
    }
  }
  // tel: USSD / MMI codes (*06# style) can leak the IMEI on Android.
  if (scheme == 'tel') {
    final body = url.substring(colon + 1);
    if (body.contains('*') || body.contains('#')) return false;
  }
  return true;
}

/// One detected span inside a source string.
class UrlMatch {
  /// Creates a span with UTF-16 [start]/[end] offsets and a canonical [url].
  const UrlMatch({
    required this.start,
    required this.end,
    required this.url,
    required this.kind,
  });

  /// Inclusive UTF-16 code-unit offset.
  final int start;

  /// Exclusive UTF-16 code-unit offset.
  final int end;

  /// Canonical openable URL: `www.x.com` → `http://www.x.com`,
  /// phone → `tel:<digits>`, email → `mailto:<addr>`.
  final String url;

  /// What kind of thing was detected.
  final UrlMatchKind kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UrlMatch &&
          start == other.start &&
          end == other.end &&
          kind == other.kind &&
          url == other.url;

  @override
  int get hashCode => Object.hash(start, end, kind, url);

  @override
  String toString() => 'UrlMatch($kind, [$start,$end), $url)';
}

/// Categorizes a [UrlMatch] for tap routing and styling.
enum UrlMatchKind {
  /// http(s) and custom-scheme URLs.
  web,

  /// Email address → `mailto:` URL.
  email,

  /// Phone number → `tel:` URL.
  phone;

  /// Stable byte tag shared across the FFI boundary and the on-disk codec.
  int get wireByte => index;

  /// Lenient decode: unknown bytes fall back to [web] so a DB row written
  /// by a future build (e.g. a new kind we haven't added yet) still
  /// renders as a tappable link after a downgrade.
  static UrlMatchKind fromByte(int b) {
    if (b >= 0 && b < UrlMatchKind.values.length) {
      return UrlMatchKind.values[b];
    }
    return UrlMatchKind.web;
  }
}

// ---------------------------------------------------------------------------
// FFI binding
// ---------------------------------------------------------------------------

/// Native signature:
///   uint8_t* ux_match_url(const uint16_t* utf16, int32_t len, int32_t* out_size);
///
/// Returned buffer is malloc'd by native (caller frees via [ux_free]):
///   u32 count
///   count * { i32 start, i32 end, u32 kind, u32 url_len, u8[url_len] url_utf8 }
typedef _MatchUrlNative = Pointer<Uint8> Function(
    Pointer<Uint16> utf16, Int32 len, Pointer<Int32> outSize);
typedef _MatchUrl = Pointer<Uint8> Function(
    Pointer<Uint16> utf16, int len, Pointer<Int32> outSize);

typedef _FreeNative = Void Function(Pointer<Uint8> buf);
typedef _Free = void Function(Pointer<Uint8> buf);

_MatchUrl? _lookupMatchUrl() {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<_MatchUrlNative>>('ux_match_url').asFunction();
  } catch (_) {
    return null;
  }
}

_Free? _lookupFree() {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<_FreeNative>>('ux_free').asFunction();
  } catch (_) {
    return null;
  }
}

final _MatchUrl? _matchUrl = _lookupMatchUrl();
final _Free? _free = _lookupFree();

bool _hasSigil(String text) {
  for (int i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x2E /* . */ ||
        c == 0x3A /* : */ ||
        c == 0x40 /* @ */ ||
        c == 0x2B /* + */) {
      return true;
    }
  }
  return false;
}

// Hard cap on matches we'll surface per message — defends against a
// sender crafting text designed to balloon a chat bubble's recognizer
// count. 64 is well above any real chat density.
const int _kMaxMatchesPerMessage = 64;

List<UrlMatch> _decode(Uint8List buf) {
  if (buf.length < 4) return const [];
  final view = ByteData.sublistView(buf);
  final count = view.getUint32(0, Endian.little);
  if (count == 0) return const [];
  final capped = count > _kMaxMatchesPerMessage ? _kMaxMatchesPerMessage : count;
  final out = <UrlMatch>[];
  int p = 4;
  for (int i = 0; i < capped; i++) {
    if (p + 16 > buf.length) break;
    final start = view.getInt32(p, Endian.little);
    final end = view.getInt32(p + 4, Endian.little);
    final kindByte = view.getUint32(p + 8, Endian.little);
    final urlLen = view.getUint32(p + 12, Endian.little);
    p += 16;
    if (p + urlLen > buf.length) break;
    final url = utf8.decode(Uint8List.sublistView(buf, p, p + urlLen));
    p += urlLen;
    out.add(UrlMatch(
      start: start,
      end: end,
      url: url,
      kind: UrlMatchKind.fromByte(kindByte),
    ));
  }
  return out;
}
