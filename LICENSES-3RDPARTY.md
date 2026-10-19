# ux — Third-Party Licenses & Compliance

`ux` can bundle two components with distribution obligations: **FFmpeg**, used
as a software H.264 video decoder on Android, and AOSP's **link patterns**,
compiled into the Windows plugin and ported into ux's Dart link detector. FFmpeg is **opt-in and disabled by
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

## android.util.Patterns (Apache-2.0)

[lib/src/url/](lib/src/url/) holds scanners ported from the regular
expressions of AOSP's `android.util.Patterns`, Copyright (C) 2007 The Android
Open Source Project, licensed under the
[Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0), on
every platform: `WEB_URL`'s character classes and host grammar in
`web_pass.dart`, and `EMAIL_ADDRESS`'s local-part class in `email.dart`.

## Unicode data (Unicode License v3)

[tool/url_data/unicode-17.0.0/](tool/url_data/unicode-17.0.0/) holds
`DerivedGeneralCategory.txt` and `DerivedCoreProperties.txt` of Unicode 17.0.0,
unmodified, from https://www.unicode.org/Public/17.0.0/. This notice covers
those files and every table generated from them:

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2025 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

## Release checklist
- [ ] FFmpeg/Media3 tags unchanged, or doc + archived source updated if bumped.
- [ ] Build still omits `--enable-gpl` / `--enable-nonfree`; decode-only.
- [ ] `registerFfmpegLicense()` reachable (auto on video, or eager at startup).
- [ ] FFmpeg `release/6.0` source tarball + scripts archived for this version.
