# ux — architecture

This doc maps the load-bearing modules in the `ux` Flutter package: where
each lives, what it owns, and which native pieces back it on each
platform. Banlu is the primary consumer; everything here is meant to be
reusable across other Flutter apps that depend on `ux`.

Conventions:

* Source paths are anchored at the package root (e.g. `lib/src/...`).
* Native paths use `android/...` and `darwin/...` (shared
  iOS+macOS sources) or `ios/` / `macos/` (platform-specific).
* "Banned" means: don't reintroduce. Lints and tests exist to catch
  regressions where applicable.

---

## Module map

| Module | Dart | Android | Apple |
|---|---|---|---|
| `XKeyboard` — frame-accurate keyboard tracking + interactive dismiss | [lib/src/keyboard/](../lib/src/keyboard/) | [android/src/main/jni/keyboard_bridge.c](../android/src/main/jni/keyboard_bridge.c) | [darwin/Keyboard/](../darwin/Keyboard/) |
| `XSensors` — gyro / accelerometer over JNI/FFI | [lib/src/sensors/](../lib/src/sensors/) | [android/src/main/jni/sensor_bridge.c](../android/src/main/jni/sensor_bridge.c) | [darwin/Sensors/](../darwin/Sensors/) |
| `XCamera` — CameraX (Android) / AVCaptureSession (Apple) | [lib/src/camera/](../lib/src/camera/) | [android/src/main/kotlin/io/swipelab/ux/camera/](../android/src/main/kotlin/io/swipelab/ux/camera/) | [darwin/Camera/](../darwin/Camera/) |
| `XScanner` — ZXing QR scanner (Android) / VNDetect (Apple) | [lib/src/scanner/](../lib/src/scanner/) | [android/src/main/kotlin/io/swipelab/ux/scanner/](../android/src/main/kotlin/io/swipelab/ux/scanner/) | [darwin/Scanner/](../darwin/Scanner/) |
| `XVideoPlayer` — ExoPlayer (Android) / AVPlayer (Apple) | [lib/src/video/](../lib/src/video/) | [android/src/main/kotlin/io/swipelab/ux/video/](../android/src/main/kotlin/io/swipelab/ux/video/) | [darwin/Video/](../darwin/Video/) |
| `XVideoExporter` — trim / mute / crop-rotate-flip video export: Media3 Transformer (Android) / AVAssetExportSession passthrough remux with re-encode fallback, `AVAssetReader`/`Writer` + per-frame `AVMutableVideoComposition` for the transform path (Apple). Trim+mute alone stays a passthrough remux; a crop/rotate/mirror request re-encodes at a telegram bitrate tier (480/640/848/1280/1920 · 400–6600 kbps H.264+AAC). Geometry is a caller-supplied source→output affine (`transform3x3` + `outWidth`/`outHeight`) in upright **native source pixels**, applied verbatim so the output matches the caller's on-screen preview. Session API: progress stream + cancel over `ux/video/export` (+`/events`). Consumer: banlu's compose video editing (telegram-parity trim/mute/crop). | [lib/src/video/x_video_exporter.dart](../lib/src/video/x_video_exporter.dart) | [android/.../video/VideoExporterPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/video/VideoExporterPlugin.kt) | [darwin/Video/VideoExporterPlugin.swift](../darwin/Video/VideoExporterPlugin.swift) |
| `XNotifications` — OS notifications: show / cancel / tap / authorization | [lib/src/notifications/](../lib/src/notifications/) | [android/.../NotificationsPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/NotificationsPlugin.kt) | [macos/Classes/NotificationsPlugin.swift](../macos/Classes/NotificationsPlugin.swift) (macOS only) |
| `XWindow` — host focus state (`focused`) | [lib/src/window/](../lib/src/window/) | [android/.../WindowPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/WindowPlugin.kt) | [macos/Classes/WindowPlugin.swift](../macos/Classes/WindowPlugin.swift) (macOS only) |
| `XFile`, navi — see source | [lib/src/](../lib/src/) | mixed | mixed |

---

## Video pipeline (Android)

The Android video stack is the most involved piece in `ux` because it
spans four cooperating layers (Dart controller → Kotlin player
instance → Media3 ExoPlayer → GL compositor → Flutter texture). It
also carries the most production-load-bearing fix: a vendored FFmpeg
video decoder that fronts the platform `MediaCodec` path for files
the OEM hardware decoder can't handle.

### Layers

```
Dart  XVideoPlayerController (lib/src/video/x_video_player.dart)
       │   MethodChannel `ux/video`
       ▼
Kotlin VideoPlayerInstance (one per Dart controller)
       │   owns:
       │   ├── ExoPlayer  (Media3 1.9.2; renderers wired via Renderers.kt)
       │   ├── VideoCompositor (codec output → Flutter texture; GL blit)
       │   └── Flutter SurfaceTextureEntry (the texture id Dart Texture() samples)
       ▼
Native Media3 video renderer
       │   tier 1: FfmpegVideoRenderer  (libavcodec, SW decode, GL YUV→RGB)
       │   tier 2: MediaCodecVideoRenderer (HW path; HiSilicon C2 decoders
       │           deprioritised so EMUI 10/11 falls through to c2.android.avc.decoder)
       ▼
GL    SurfaceTexture (compositor input)
       │   compositor reads + applies SurfaceTexture transform
       │   blits to Flutter SurfaceTexture (output)
       ▼
Flutter Texture widget samples the SurfaceTexture, scales to widget size
```

### Files

| What | Where |
|---|---|
| Dart controller | [lib/src/video/x_video_player.dart](../lib/src/video/x_video_player.dart) |
| MethodChannel binding | [lib/src/video/x_video_player_channel.dart](../lib/src/video/x_video_player_channel.dart) |
| Texture widget | [lib/src/video/x_video_player_view.dart](../lib/src/video/x_video_player_view.dart) |
| Per-controller native player | [android/src/main/kotlin/io/swipelab/ux/video/VideoPlayerInstance.kt](../android/src/main/kotlin/io/swipelab/ux/video/VideoPlayerInstance.kt) |
| ExoPlayer renderer factory | [android/src/main/kotlin/io/swipelab/ux/video/Renderers.kt](../android/src/main/kotlin/io/swipelab/ux/video/Renderers.kt) |
| GL blit between codec and Flutter texture | [android/src/main/kotlin/io/swipelab/ux/video/VideoCompositor.kt](../android/src/main/kotlin/io/swipelab/ux/video/VideoCompositor.kt) |
| FFmpeg renderer (Java) | [android/src/main/java/io/swipelab/ux/video/ffmpeg/](../android/src/main/java/io/swipelab/ux/video/ffmpeg/) |
| FFmpeg JNI source | [android/ffmpeg/ffmpeg_jni.cc](../android/ffmpeg/ffmpeg_jni.cc) |
| FFmpeg build orchestrator | [android/ffmpeg/build_ffmpeg.sh](../android/ffmpeg/build_ffmpeg.sh) |

### Renderer selection (`Renderers.kt`)

`Renderers.build(context, surfaceSizer)` returns a `DefaultRenderersFactory`
subclass that builds the video renderer list with FFmpeg first and
MediaCodec second:

1. **`FfmpegVideoRenderer`** — picked when `FfmpegLibrary.isAvailable()`
   returns true (i.e. `libffmpegJNI.so` is loaded for the device's ABI)
   *and* the format is H.264. Software decode via libavcodec, no DPB
   cap, handles iOS `yuvj420p` (full-range) and deep B-frame reorder
   structures that defeat platform decoders on older Huawei silicon.
   YUV→RGB happens in a one-pass GLES2 shader inside
   `FfmpegOutputSurface`. Y plane uses `GL_NEAREST` filtering (1:1
   sized to the EGL surface, sampling at exact texel centres preserves
   luma detail); chroma uses `GL_LINEAR` for clean 4:2:0 upsampling.
2. **`MediaCodecVideoRenderer`** (Media3 default) — picked for any
   other format, or if FFmpeg is unavailable. Two non-default tweaks:
   * `setEnableDecoderFallback(true)` so init-time failures bounce to
     the next decoder.
   * Custom `MediaCodecSelector` deprioritises every HiSilicon
     decoder (`OMX.hisi.*` and `c2.hisi.*`). The EMUI 10 OMX variant
     fails codec start (caught by fallback); the EMUI 11 C2 variant
     initialises cleanly but errors on the first sample, which
     fallback can't catch — name-based deprioritisation is the only
     way past it when FFmpeg is unavailable for that ABI.

The two-tier design is intentional: FFmpeg adds a slight battery cost
vs. hardware decoding, but it's the only path that reliably plays the
full range of producer-side content (iOS recordings in particular).
Hardware stays as the fallback for the formats and devices where it
works.

### Why we vendor an FFmpeg video renderer

Media3's published `decoder-ffmpeg` is audio-only.
`ExperimentalFfmpegVideoRenderer` in the same library has been a stub
since 2020 (`createDecoder` returns null, `supportsFormat` returns
`FORMAT_UNSUPPORTED_TYPE`). The only well-maintained community
alternative (NextLib) is GPL-3.0 — would impose copyleft on every
consumer. So we ship our own Apache-licensed JNI on top of the LGPL
FFmpeg, vendored under `android/ffmpeg/`.

### How the FFmpeg `.so` gets built

There are no native binaries in the repo. The `:ux:buildFfmpegJni`
Gradle task (wired to `preBuild` in
[android/build.gradle](../android/build.gradle)) handles everything:

1. Clones Media3 (`1.9.2`) and FFmpeg (`release/6.0`) into the
   consumer's `build/ffmpeg-work/` on first run.
2. Drops the vendored `ffmpeg_jni.cc` + `CMakeLists.txt` over the
   upstream copies (so the produced JNI exposes the video entry points
   `FfmpegVideoDecoder.java` calls).
3. Cross-builds FFmpeg static libs (H.264 only) for all 4 Android ABIs.
4. Links `libffmpegJNI.so` per ABI and writes them into
   `<ux-build>/jniLibs/<abi>/`, which AGP picks up via
   `sourceSets.main.jniLibs.srcDirs +=`.

Up-to-date checking on `ffmpeg_jni.cc` + `CMakeLists.txt` +
`build_ffmpeg.sh` means subsequent builds skip the task entirely. The
slow part (FFmpeg static-lib build, ~30 min on an x86 host, ~2 min on
Apple Silicon) only happens on the first build for a given checkout,
or after a `gradle clean`.

License: FFmpeg is LGPL v2.1, linked dynamically at runtime via
`System.loadLibrary("ffmpegJNI")` — the LGPL boundary stays intact.
The build config omits `--enable-gpl` and `--enable-nonfree`. See
[android/ffmpeg/LICENSE-FFMPEG.txt](../android/ffmpeg/LICENSE-FFMPEG.txt)
and [android/ffmpeg/README.md](../android/ffmpeg/README.md).

### Looping and end-of-stream

`XVideoPlayerController.setLooping(true)` maps to ExoPlayer's
`REPEAT_MODE_ONE` (the entire seek-to-0-and-resume cycle is handled
in-engine). Non-looping playback emits a `completed` event when
`STATE_ENDED` is reached without repeat — see
`VideoPlayerInstance.kt`. Consumers that need tap-play-at-end-restarts
behavior (Telegram parity) check `position` against `duration` on the
Dart side and call `seekTo(Duration.zero)` before `play()` when within
2 seconds of the end.

---

## Video pipeline (Apple)

`AVPlayer` + `AVPlayerItem` + `AVPlayerItemVideoOutput`. No FFmpeg
fallback needed — `AVFoundation` handles iOS-produced H.264 (and HEVC)
directly without the DPB-cap / full-range quirks the Android platform
decoders trip over. See
[darwin/Video/VideoPlayerInstance.swift](../darwin/Video/VideoPlayerInstance.swift).

## Notifications + window focus

`XNotifications` and `XWindow` share a two-channel shape: a `MethodChannel`
for commands and an `EventChannel` for native-pushed events. Each Dart
constructor only subscribes to its `EventChannel` on platforms that
register a native handler (`defaultTargetPlatform` gate) — otherwise
activating the stream throws `MissingPluginException`, which Flutter
reports straight to `FlutterError.onError`.

Handler coverage:

| | macOS | Android | iOS |
|---|---|---|---|
| `XWindow` (`ux/window/events`) | `NSApplication` active/resign | `ProcessLifecycleOwner` `ON_START`/`ON_STOP` | none — `focused` stays `true` |
| `XNotifications` (`ux/notifications` + `…/events`) | `UNUserNotificationCenter` | `NotificationManagerCompat` + `POST_NOTIFICATIONS` | none |

On Android the two are coupled: `XWindow.focused` flipping to `false`
when the app backgrounds is what lets a consumer (Banlu's
`MessageNotifier`) post a local notification for a live socket message
while the process is alive but unfocused — the gap FCM intentionally
skips for socket-connected devices. The notification's tap `PendingIntent`
relaunches the app's launcher activity (resolved generically via
`getLaunchIntentForPackage`, no app class hard-coded) carrying the `data`
payload, which the plugin re-emits as a `tap` event; a tap that cold-starts
the process is buffered until Dart subscribes.
