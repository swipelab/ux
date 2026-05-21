import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ux/src/_ffi.dart';

/// Native URL / phone / email detection plus an OS-handler launcher.
class XUrl {
  XUrl._();

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
  // Bidi controls + directional marks let a sender visually reverse the
  // displayed URL while the byte order — what the OS opens — points
  // elsewhere. Reject rather than guessing intent.
  for (int i = 0; i < url.length; i++) {
    final c = url.codeUnitAt(i);
    if (c == 0x200E || c == 0x200F /* LRM / RLM */ ||
        (c >= 0x202A && c <= 0x202E) ||
        (c >= 0x2066 && c <= 0x2069)) {
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

/// Strips invisible / whitespace chars that NSDataDetector or
/// `Patterns.WEB_URL` sometimes drag inside a URL — typically when the
/// source text uses them as soft separators. Leaving them in produces a
/// URL the OS refuses to open later. Bidi-override chars are NOT
/// stripped here (they survive into [_isLaunchable] which rejects them
/// outright; see comment there).
String _sanitizeUrl(String url) {
  StringBuffer? out;
  for (int i = 0; i < url.length; i++) {
    final c = url.codeUnitAt(i);
    final strip =
        c == 0x09 /* tab */ ||
        c == 0x0A /* LF */ ||
        c == 0x0D /* CR */ ||
        c == 0xA0 /* NBSP */ ||
        (c >= 0x200B && c <= 0x200D) /* ZWSP / ZWNJ / ZWJ */ ||
        (c >= 0x2060 && c <= 0x206F) /* word joiner + invisible ops */ ||
        c == 0xFEFF /* BOM / ZWNBSP */;
    if (strip) {
      out ??= StringBuffer(url.substring(0, i));
      continue;
    }
    out?.writeCharCode(c);
  }
  return out?.toString() ?? url;
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
  int digits = 0;
  for (int i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x2E /* . */ ||
        c == 0x3A /* : */ ||
        c == 0x40 /* @ */ ||
        c == 0x2B /* + */) {
      return true;
    }
    // A phone number with no `+` and no separators (e.g. `0731098515`)
    // wouldn't otherwise reach the native detector. The native side
    // applies its own min-digit-count filter, so even a five-digit ZIP
    // here is harmless — the FFI hop is sub-ms.
    if (c >= 0x30 && c <= 0x39) {
      digits++;
      if (digits >= 5) return true;
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
    final url = _sanitizeUrl(
      utf8.decode(Uint8List.sublistView(buf, p, p + urlLen)),
    );
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
