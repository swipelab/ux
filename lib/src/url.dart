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
    final detect = debugDetect ?? _detect;
    if (detect == null) return const [];
    final native = _tightenPhoneMatches(_decode(detect(text), text), text);
    return _mergeCustomSchemeMatches(native, text);
  }

  /// Stands in for the native detector, which `flutter test` does not load:
  /// the buffer `ux_match_url` answers for a text, empty where it finds
  /// nothing.
  @visibleForTesting
  static Uint8List Function(String text)? debugDetect;

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
    if (!(Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows)) {
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

  /// Opens the OS settings the user needs to grant this app a permission it
  /// has denied. Returns false when the settings surface cannot be reached.
  ///
  /// iOS and Android land on this app's own page —
  /// `UIApplication.openSettingsURLString` and
  /// `ACTION_APPLICATION_DETAILS_SETTINGS` for the host package. macOS has no
  /// per-app page, so it opens the Privacy & Security pane of System
  /// Settings, where camera / microphone / screen-recording access lives.
  static Future<bool> openAppSettings() async {
    if (kIsWeb) return false;
    if (!(Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) {
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('openAppSettings');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

const Set<String> _kLaunchSchemes = {
  'http',
  'https',
  'mailto',
  'tel',
  'sms',
  'banlu',
  'tg',
};

bool _isLaunchable(String url) {
  final colon = url.indexOf(':');
  if (colon <= 0) return false;
  final scheme = url.substring(0, colon).toLowerCase();
  if (!_kLaunchSchemes.contains(scheme)) return false;
  if (url.codeUnits.any(_isBidiControl)) return false;
  // tel: USSD / MMI codes (*06# style) can leak the IMEI on Android.
  if (scheme == 'tel') {
    final body = url.substring(colon + 1);
    if (body.contains('*') || body.contains('#')) return false;
  }
  return true;
}

/// Whether [c] is one of Unicode's Bidi_Control characters, which let a
/// sender visually reverse a displayed URL while the byte order — what the
/// OS opens — points elsewhere.
bool _isBidiControl(int c) =>
    c == 0x061C /* ALM */ ||
    c == 0x200E ||
    c == 0x200F /* LRM / RLM */ ||
    (c >= 0x202A && c <= 0x202E) ||
    (c >= 0x2066 && c <= 0x2069);

/// [url], the native detector's URL for the link of [text] from [start] to
/// [end], or, where the link's text holds a bidi control that [url] leaves
/// out, as NSDataDetector's email and phone URLs do, [url]'s scheme and then
/// the text, or the text alone where it starts with that scheme, so
/// [_isLaunchable] refuses it as it does a web link, whose URL keeps its text.
String _keepBidiControls(String url, String text, int start, int end) {
  if (url.codeUnits.any(_isBidiControl)) return url;
  final linked = text.substring(start, end);
  if (!linked.codeUnits.any(_isBidiControl)) return url;
  final scheme = url.substring(0, url.indexOf(':') + 1).toLowerCase();
  return linked.toLowerCase().startsWith(scheme) ? linked : '$scheme$linked';
}

/// Strips invisible / whitespace chars that NSDataDetector or
/// `Patterns.WEB_URL` sometimes drag inside a URL — typically when the
/// source text uses them as soft separators. Leaving them in produces a
/// URL the OS refuses to open later. The bidi controls ([_isBidiControl])
/// are NOT stripped here, so they survive into [_isLaunchable], which
/// rejects them.
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
        (c >= 0x2060 && c <= 0x2065) /* word joiner + invisible ops */ ||
        (c >= 0x206A && c <= 0x206F) /* deprecated format controls */ ||
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

  /// Canonical URL: `www.x.com` → `http://www.x.com`, phone →
  /// `tel:<digits>`, email → `mailto:<addr>`. Where the link's text
  /// holds a bidi control that the native detector's URL leaves out, it is
  /// that URL's scheme and then the text, or the text alone where it starts
  /// with that scheme, such as `tel:+1 ` and a right-to-left mark before
  /// `555 123 4567`, which [XUrl.launch] refuses.
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
  Pointer<Uint16> utf16,
  Int32 len,
  Pointer<Int32> outSize,
);
typedef _MatchUrl = Pointer<Uint8> Function(
  Pointer<Uint16> utf16,
  int len,
  Pointer<Int32> outSize,
);

typedef _FreeNative = Void Function(Pointer<Uint8> buf);
typedef _Free = void Function(Pointer<Uint8> buf);

_MatchUrl? _lookupMatchUrl() {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib
        .lookup<NativeFunction<_MatchUrlNative>>('ux_match_url')
        .asFunction();
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

Uint8List Function(String text)? _bindDetect() {
  final detect = _lookupMatchUrl();
  final free = _lookupFree();
  if (detect == null || free == null) return null;
  return (text) {
    final inPtr = text.toNativeUtf16(allocator: calloc);
    final sizePtr = calloc<Int32>();
    Pointer<Uint8> out = nullptr;
    try {
      out = detect(inPtr.cast<Uint16>(), text.length, sizePtr);
      final size = sizePtr.value;
      return out == nullptr || size <= 0
          ? Uint8List(0)
          : Uint8List.fromList(out.asTypedList(size));
    } finally {
      calloc.free(inPtr);
      calloc.free(sizePtr);
      if (out != nullptr) free(out);
    }
  };
}

final Uint8List Function(String text)? _detect = _bindDetect();

bool _hasSigil(String text) {
  int digits = 0;
  for (int i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x2E /* . */ ||
        c == 0x3A /* : */ ||
        c == 0x40 /* @ */ ||
        c == 0x2B /* + */ ) {
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

/// Drop phone candidates that don't look like real phones. Two checks:
///   1. The character immediately before the match (if any) must be
///      whitespace. Anything else — letter, digit, `-`, `:`, `/`, … —
///      means the digits are glued to surrounding text (identifiers
///      like `order-1778829224857`, URLs, hashes) and are not a phone.
///   2. The slice must start with `(`, `+`, or `0`. International
///      numbers begin with `+`, US-style begins with `(area)`, most
///      domestic formats outside the US use a `0` trunk prefix.
List<UrlMatch> _tightenPhoneMatches(List<UrlMatch> matches, String text) {
  if (matches.isEmpty) return matches;
  final out = <UrlMatch>[];
  for (final m in matches) {
    if (m.kind == UrlMatchKind.phone &&
        (!_phoneLeftBoundaryOk(text, m.start) ||
            !_phoneLeadingCharOk(text, m.start, m.end))) {
      continue;
    }
    out.add(m);
  }
  return out;
}

bool _phoneLeftBoundaryOk(String text, int start) {
  if (start <= 0) return true;
  final c = text.codeUnitAt(start - 1);
  return c == 0x20 /* space */ ||
      c == 0x09 /* tab */ ||
      c == 0x0A /* LF */ ||
      c == 0x0D /* CR */ ||
      c == 0xA0 /* NBSP */ ||
      c == 0x3000 /* ideographic space */ ||
      c == 0x2028 /* line separator */ ||
      c == 0x2029 /* paragraph separator */;
}

bool _phoneLeadingCharOk(String text, int start, int end) {
  final hi = end > text.length ? text.length : end;
  final lo = start < 0 ? 0 : start;
  if (lo >= hi) return false;
  final first = text.codeUnitAt(lo);
  return first == 0x28 /* ( */ ||
      first == 0x2B /* + */ ||
      first == 0x30 /* 0 */;
}

/// AOSP's `Patterns.WEB_URL` only accepts http/https/ftp/rtsp, so any
/// other `scheme://…` (bl://, tg://, intent://, …) is invisible to the
/// native detector on Android. NSDataDetector on iOS is permissive but
/// not exhaustive. This pass surfaces every RFC-3986 scheme so the
/// renderer can style and the tap router can decide; [_dedupeMatches]
/// collapses anything overlapping with what native already found. A match
/// takes the scheme characters before its `://` from where they begin, and
/// its link starts at their first letter, so a `_` or a digit before a scheme
/// does not keep it from linking, as `Patterns.WEB_URL` links an http URL
/// after one. A match ends before whitespace, a C0 or C1 control or DEL, CJK
/// punctuation (U+3000's block's punctuation and the vertical, compatibility,
/// small, fullwidth and halfwidth forms of punctuation) and the ASCII marks
/// `Patterns.WEB_URL`'s path does not take: `"`, `<`, `>`, `[`, `\`, `]`, `^`,
/// `` ` ``, `{`, `|`, `}` and a `%` that two hex digits do not follow. A
/// bracketed IP literal host, after any userinfo, keeps its brackets.
final RegExp _kAnySchemeRegex = RegExp(
  // Matching from where the scheme characters begin scans each run once.
  r'(?<![a-zA-Z0-9+.\-])([0-9+.\-]*)[a-zA-Z][a-zA-Z0-9+.\-]*://'
  r"(?:(?:(?:[\w\-.~!$&'()*+,;=:]|%[0-9a-fA-F]{2})*@)?\[[0-9a-fA-F:.]+\])?"
  r'(?:[^\s\x00-\x1F\x7F-\x9F"%<>\[\\\]^`{|}'
  r'\u3001-\u3003\u3008-\u3011\u3014-\u301F\uFE10-\uFE19\uFE30-\uFE6B'
  r'\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65]|%[0-9a-fA-F]{2})+',
);

List<UrlMatch> _mergeCustomSchemeMatches(List<UrlMatch> native, String text) {
  if (!text.contains('://')) return native;
  final extra = <UrlMatch>[];
  for (final m in _kAnySchemeRegex.allMatches(text)) {
    final start = m.start + m[1]!.length;
    final end = _trimUrlTrailingPunctuation(text, start, m.end);
    if (end - start < 4 /* "x://" minimum */ ) continue;
    extra.add(
      UrlMatch(
        start: start,
        end: end,
        url: _sanitizeUrl(text.substring(start, end)),
        kind: UrlMatchKind.web,
      ),
    );
  }
  if (extra.isEmpty) return native;
  return _dedupeMatches([...native, ...extra]);
}

/// The end of the [_kAnySchemeRegex] link [start, end) before a trailing `.`,
/// `,`, `;`, `!`, `'` or `(` and a trailing `)` the link does not open, as the
/// native detectors end a web link (`bl://x?code=1.` → `bl://x?code=1`).
int _trimUrlTrailingPunctuation(String text, int start, int end) {
  int unopened = 0;
  for (int i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x29 /* ) */ ) unopened++;
    if (c == 0x28 /* ( */ ) unopened--;
  }
  while (end > start) {
    final c = text.codeUnitAt(end - 1);
    if (c == 0x29 /* ) */ && unopened > 0) {
      unopened--;
    } else if (c == 0x28 /* ( */ ) {
      unopened++;
    } else if (!(c == 0x2E /* . */ ||
        c == 0x2C /* , */ ||
        c == 0x3B /* ; */ ||
        c == 0x21 /* ! */ ||
        c == 0x27 /* ' */ )) {
      break;
    }
    end--;
  }
  return end;
}

/// Greedy de-overlap: sort by start asc, longer-first on tie, then drop
/// any match whose start falls inside the previously kept match.
List<UrlMatch> _dedupeMatches(List<UrlMatch> matches) {
  matches.sort((a, b) {
    if (a.start != b.start) return a.start.compareTo(b.start);
    final lenA = a.end - a.start;
    final lenB = b.end - b.start;
    if (lenA != lenB) return lenB.compareTo(lenA);
    return b.kind.index.compareTo(a.kind.index);
  });
  final out = <UrlMatch>[];
  int lastEnd = 0;
  bool any = false;
  for (final m in matches) {
    if (any && m.start < lastEnd) continue;
    out.add(m);
    lastEnd = m.end;
    any = true;
  }
  return out;
}

List<UrlMatch> _decode(Uint8List buf, String text) {
  if (buf.length < 4) return const [];
  final view = ByteData.sublistView(buf);
  final count = view.getUint32(0, Endian.little);
  if (count == 0) return const [];
  final capped = count > _kMaxMatchesPerMessage
      ? _kMaxMatchesPerMessage
      : count;
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
      _keepBidiControls(
        utf8.decode(Uint8List.sublistView(buf, p, p + urlLen)),
        text,
        start,
        end,
      ),
    );
    p += urlLen;
    out.add(
      UrlMatch(
        start: start,
        end: end,
        url: url,
        kind: UrlMatchKind.fromByte(kindByte),
      ),
    );
  }
  return out;
}
