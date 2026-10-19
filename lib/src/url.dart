import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:ux/src/_ffi.dart';
import 'package:ux/src/url/detect.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/phones.dart';

/// Link detection in text, with the platform's phones on iOS and Android,
/// plus an OS-handler launcher.
class XUrl {
  XUrl._();

  static const _channel = MethodChannel('ux/url');

  /// The web links and emails of [text], and on iOS and Android the phones
  /// the platform's detector reads that overlap none of them, sorted by
  /// [UrlMatch.start] and non-overlapping, with UTF-16 offsets.
  static List<UrlMatch> match(String text) {
    final links = detectLinks(text);
    final read = _readPhones;
    return read == null ? links : withPhones(text, links, read);
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

/// The platform's phone detector, on iOS and Android.
final PhoneReader? _readPhones = _bindPhones();

/// `uint8_t *ux_match_phones(const uint16_t *utf16, int32_t len, int32_t
/// *out_size)`: a buffer of `out_size` bytes in the platform's byte order, a
/// u32 count and then, for each phone, its i32 start, i32 end and u32 length
/// and that many UTF-16 units of its phone string, which `ux_free` frees.
typedef _MatchPhonesNative = Pointer<Uint8> Function(
  Pointer<Uint16>,
  Int32,
  Pointer<Int32>,
);
typedef _MatchPhones = Pointer<Uint8> Function(
  Pointer<Uint16>,
  int,
  Pointer<Int32>,
);

typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _Free = void Function(Pointer<Uint8>);

PhoneReader? _bindPhones() {
  final lib = uxLib;
  if (lib == null || !(Platform.isIOS || Platform.isAndroid)) return null;
  final match = lib.lookupFunction<_MatchPhonesNative, _MatchPhones>(
    'ux_match_phones',
  );
  final free = lib.lookupFunction<_FreeNative, _Free>('ux_free');
  return (text, length) {
    final units = text.toNativeUtf16(allocator: calloc);
    final size = calloc<Int32>();
    final buf = match(units.cast(), length, size);
    try {
      final bytes = buf.asTypedList(size.value);
      final view = ByteData.sublistView(bytes);
      final phones = <PlatformPhone>[];
      var p = 4;
      for (var i = view.getUint32(0, Endian.host); i > 0; i--) {
        final phone = p + 12 + 2 * view.getUint32(p + 8, Endian.host);
        phones.add((
          start: view.getInt32(p, Endian.host),
          end: view.getInt32(p + 4, Endian.host),
          phone: String.fromCharCodes(
            Uint16List.sublistView(bytes, p + 12, phone),
          ),
        ));
        p = phone;
      }
      return phones;
    } finally {
      free(buf);
      calloc.free(units);
      calloc.free(size);
    }
  };
}
