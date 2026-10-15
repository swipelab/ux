# ux — Third-Party Licenses & Compliance

`ux` can bundle two components with distribution obligations: **FFmpeg**, used
as a software H.264 video decoder on Android, and AOSP's **link patterns**,
compiled into the Windows plugin. FFmpeg is **opt-in and disabled by
default** — only apps that enable it ship it and inherit the obligation:

```yaml
ux:
  enable_ffmpeg: true
```

That pubspec flag is the single source of truth: Gradle reads it for the
native build, and ux's build_runner builder generates a `kUxEnableFfmpeg`
constant from it into the app's `app_info.g.dart`, which gates
`registerFfmpegLicense()` at startup — so the in-app LGPL notice follows
automatically, eagerly, with no `--dart-define`.

Apps that enable it need to (a) surface a license UI and (b) be able to honor
the source offer below; apps that leave it disabled have no FFmpeg obligation
(and the in-app notice never appears).

## FFmpeg (LGPL-2.1) — Android only

### What and where
Compiled from source into `libffmpegJNI.so` per ABI and loaded at runtime via
`System.loadLibrary` — an ExoPlayer/Media3 fallback **decode-only** renderer.
Not a pub/Dart dependency. iOS/macOS use AVFoundation → **no FFmpeg, no
obligation** there.

- Build wiring: [android/ffmpeg/](android/ffmpeg/) — `build_ffmpeg.sh`,
  `CMakeLists.txt`, `ffmpeg_jni.cc`, `README.md`, `LICENSE-FFMPEG.txt`.
- Attribution: [lib/builder.dart](lib/builder.dart) generates a
  `kUxEnableFfmpeg` constant from the app's `ux: enable_ffmpeg` pubspec flag
  into `app_info.g.dart`; the app gates
  [registerFfmpegLicense()](lib/src/video/ffmpeg_license.dart) on it at
  startup (`if (kUxEnableFfmpeg) registerFfmpegLicense();`). So a build with
  the flag off registers nothing, and an enabled build shows the notice
  eagerly. Idempotent.
- Bundled LGPL text asset: `assets/licenses/ffmpeg_LGPL-2.1.txt`.

### Versions (pinned)
- FFmpeg **`release/6.0`** (upstream `git.ffmpeg.org`)
- Media3 **`1.9.2`** (JNI/renderer skeleton)

### License posture
- **LGPL v2.1**, dynamic boundary (separate, replaceable `.so`) → **no
  copyleft on the consuming app**.
- Built **decode-only** (H.264 decoder, **no encoders**) and **WITHOUT
  `--enable-gpl` / `--enable-nonfree`** → **LGPL-only**. See `build_ffmpeg.sh`.

### How we comply (LGPL-2.1)
1. **Attribution + license text** — registered via `registerFfmpegLicense()`,
   shown in any consuming app's license UI. ✅
2. **Corresponding source** — we make the FFmpeg `release/6.0` source **plus
   the build/link scripts** (`build_ffmpeg.sh`, `CMakeLists.txt`,
   `ffmpeg_jni.cc`) available **on request for ≥3 years**. **This does NOT
   include the application's own source code** — only the LGPL library and the
   scripts that compile/link it. Contact: **alex@swipelab.co**.
   → *Each release: archive the matching FFmpeg source tarball + the scripts.*
3. **Relink right (LGPL §6)** — `libffmpegJNI.so` is a standalone,
   user-rebuildable shared library; sources + script are here, so a modified
   FFmpeg can be rebuilt and swapped in. ✅
4. **Do not taint** — never add `--enable-gpl` / `--enable-nonfree` or
   GPL-only codecs (x264, x265, …).

### Patent note (for legal — separate from copyright)
FFmpeg's H.264 *decoder code* is LGPL, but the **H.264/AVC standard** is
patent-encumbered (Via LA pool, formerly MPEG-LA). We ship a **software AVC
decoder** — a patent/commercial matter for counsel, **not** an open-source or
store-policy issue. Exposure is limited to **decode** (no encoder shipped).

## android.util.Patterns (Apache-2.0) — Windows only

[windows/url_detect.cpp](windows/url_detect.cpp) holds the regular expressions
of AOSP's `android.util.Patterns` — `WEB_URL`, `EMAIL_ADDRESS`, `PHONE` and the
strings they are composed from — Copyright (C) 2007 The Android Open Source
Project, licensed under the
[Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
They are composed as `Patterns.java` composes them, each Java surrogate pair
written as a C++ `\U` escape, and compiled into `ux_plugin.dll`. Android reads
the platform's own `Patterns`, so ux ships no copy there.

## Release checklist
- [ ] FFmpeg/Media3 tags unchanged, or doc + archived source updated if bumped.
- [ ] Build still omits `--enable-gpl` / `--enable-nonfree`; decode-only.
- [ ] `registerFfmpegLicense()` reachable (auto on video, or eager at startup).
- [ ] FFmpeg `release/6.0` source tarball + scripts archived for this version.
