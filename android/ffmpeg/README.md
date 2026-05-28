# Vendored FFmpeg video decoder for `ux`

This directory contains the JNI source + Gradle build wiring for
`libffmpegJNI.so`, the LGPL-licensed FFmpeg shared library that backs
`io.swipelab.ux.video.ffmpeg.FfmpegVideoRenderer`. The renderer is
slotted ahead of `MediaCodecVideoRenderer` so iOS H.264 streams with
deep DPB (`has_b_frames > 8`) and full-range YUV play on devices where
the platform decoder fails (notably Huawei Mate 20 on EMUI 11).

## How it builds

The native library is produced by the `:ux:buildFfmpegJni` Gradle task,
wired as a dependency of `preBuild`. On any consumer build
(`flutter build apk`, `./gradlew assembleRelease`, IDE sync) the task
runs automatically; Gradle's UP-TO-DATE checking skips it when nothing
relevant changed.

What the task does:

1. Clones upstream Media3 (`1.9.2`) and FFmpeg (`release/6.0`) into
   `<ux-android-build>/ffmpeg-work/` if missing — once per checkout.
2. Drops the vendored `ffmpeg_jni.cc` + `CMakeLists.txt` over the
   upstream Media3 copies so the build produces a video-capable JNI.
3. Builds FFmpeg static libs (`libavcodec`, `libavutil`,
   `libswresample`) with H.264 decoder enabled for `armeabi-v7a`,
   `arm64-v8a`, `x86`, `x86_64`. Slow part — first build only
   (~30 min on a typical x86 host, ~2 min on Apple Silicon). Static
   libs are cached in `ffmpeg-work/` and reused on subsequent runs.
4. Cross-compiles `libffmpegJNI.so` per ABI via CMake + Ninja and
   writes the result into `<ux-android-build>/jniLibs/<abi>/`. AGP
   picks them up via the `jniLibs.srcDirs +=` line in
   [build.gradle](../build.gradle) and bundles them in the AAR.

What ships in git:

* `ffmpeg_jni.cc` — JNI bridge exposing the five entry points
  `FfmpegVideoDecoder.java` calls: initialize / sendPacket /
  receiveFrame / flush / release. Adapted from Media3's audio-only
  template; the audio path was dropped (MediaCodec AAC works
  everywhere we ship to).
* `CMakeLists.txt` — links the FFmpeg static libs into
  `libffmpegJNI.so`.
* `build_ffmpeg.sh` — orchestrates the clone + static-lib build +
  JNI link. Env-driven, invoked only by the Gradle task — not
  intended to be run by hand.
* `LICENSE-FFMPEG.txt` — LGPL v2.1 text. Required attribution.

**No `.so` files in git.** Everything under `<build>/jniLibs/` is
generated on demand; `/build` is already in [.gitignore](../.gitignore).

## License

FFmpeg is LGPL v2.1. We link to it dynamically (consumer apps load
`libffmpegJNI.so` at runtime via `System.loadLibrary`), which keeps the
LGPL boundary intact and does not impose copyleft on the consuming
app. The build configuration in upstream Media3's `build_ffmpeg.sh`
intentionally omits `--enable-gpl` and `--enable-nonfree` to keep the
binaries LGPL-only. Do not add codecs that require GPL configuration
(e.g. x264) — that would taint the artifact.

## Pinned versions

* Media3 `1.9.2` (matches the version used by the rest of `ux`).
* FFmpeg `release/6.0` (matches Media3's tested compatibility window).
* Android NDK is resolved via `android.ndkDirectory` from AGP — the
  NDK version your Android project pins, normally r27 on a recent
  AGP. Older NDKs may fail the 16-KB page-size alignment check
  enforced for Android 15.

Bumping either version: edit the `MEDIA3_TAG` / `FFMPEG_TAG`
constants near the top of `build_ffmpeg.sh`, then `./gradlew
:ux:buildFfmpegJni --rerun-tasks` to force a rebuild.

## Why we vendor this instead of using `media3-decoder-ffmpeg`

Media3's published FFmpeg extension is audio-only.
`ExperimentalFfmpegVideoRenderer` in the same library has been a stub
since 2020 — `createDecoder()` returns null, `supportsFormat()` returns
`FORMAT_UNSUPPORTED_TYPE`. The community alternative (NextLib) is
GPL-3.0, which would impose copyleft on consumers. So we built our own
on top of the same JNI skeleton.
