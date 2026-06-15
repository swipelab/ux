import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Whether the FFmpeg notice has already been added to [LicenseRegistry].
/// Registration adds a stream provider, so guard against duplicates.
bool _registered = false;

/// Registers the FFmpeg LGPL-2.1 attribution with [LicenseRegistry].
///
/// Call this at startup gated on the generated `kUxEnableFfmpeg` constant
/// (from `app_info.g.dart`, which the ux build_runner builder derives from the
/// app's `ux: enable_ffmpeg` pubspec flag) — e.g.
/// `if (kUxEnableFfmpeg) registerFfmpegLicense();`. That keeps pubspec the
/// single source of truth, registers eagerly (the notice shows without playing
/// a video), and needs no `--dart-define`. Idempotent — registers at most once.
void registerFfmpegLicense() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(_ffmpegLicenseEntries);
}

/// Attribution shown above the LGPL text. Keep in sync with
/// `android/ffmpeg/build_ffmpeg.sh` (`FFMPEG_TAG`) and
/// `android/ffmpeg/README.md`.
const String _attribution = '''
This application includes FFmpeg, used unmodified as a software video
decoder on Android via the "ux" package (libffmpegJNI.so, loaded at runtime).

FFmpeg is copyright (c) the FFmpeg developers and is licensed under the
GNU Lesser General Public License, version 2.1 (LGPL-2.1). The binary is
dynamically loaded by the app; the LGPL boundary is preserved and no
copyleft is imposed on the application.

Version: FFmpeg release/6.0, built from upstream source with the H.264
decoder enabled only (decode-only, no encoders). It is configured WITHOUT
--enable-gpl and WITHOUT --enable-nonfree, so the binary is LGPL-only.

The corresponding FFmpeg source and the build/link scripts (which document
the exact configure flags) are available on request for at least three
years; the application's own source code is not included in that offer.
The shared library can be rebuilt and replaced from those sources, as
required by section 6 of the LGPL. Contact: alex@swipelab.co

The full text of the LGPL v2.1 follows.''';

Stream<LicenseEntry> _ffmpegLicenseEntries() async* {
  String lgpl;
  try {
    lgpl = await rootBundle
        .loadString('packages/ux/assets/licenses/ffmpeg_LGPL-2.1.txt');
  } catch (error, stack) {
    // A missing asset must never break license collection; the attribution
    // paragraph below still names FFmpeg and its license.
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    );
    lgpl = '';
  }

  yield LicenseEntryWithLineBreaks(
    const <String>['FFmpeg (libavcodec, libavutil, libswresample)'],
    lgpl.isEmpty ? _attribution : '$_attribution\n\n$lgpl',
  );
}
