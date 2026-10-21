# Transcript desktop dependency attestation

Ground truths the transcript-desktop work (ux plan 667) builds on. Every claim
carries the file:line that establishes it and the date it was read.

Trees:

- `ux` — `/Users/agra/projects/ux` @ `ef99307`
- `babylon` — `/Users/agra/projects/babylon` @ `de4a57d`
- pinned plugin — `$FW` = `~/.pub-cache/hosted/pub.dev/flutter_webrtc-1.6.0`
- host — macOS 26.4 (build 25E246), macOS SDK `MacOSX26.5.sdk`

Objective-C paths below are relative to `$FW/common/darwin/Classes/`; Dart
paths to `$FW/lib/`.

## 1. flutter_webrtc 1.6.0 pin

| Claim | Evidence | Date |
| --- | --- | --- |
| Babylon's app declares flutter_webrtc as a direct runtime dependency at `^1.6.0`. | `babylon/apps/app/pubspec.yaml:19` | 2026-08-06 |
| That constraint resolves to 1.6.0 from pub.dev with archive sha256 `e997161d7da3adedd3d430691b20931b0b4d96fa48bb60938d9ba0bf6fca98be`. | `babylon/apps/app/pubspec.lock:155-162` | 2026-08-06 |
| The ux example declares flutter_webrtc as a dev dependency at `^1.5.2`. | `ux/example/pubspec.yaml:16` | 2026-08-06 |
| That constraint resolves to 1.6.0 with the same archive sha256, as `direct dev`. | `ux/example/pubspec.lock:251-258` | 2026-08-06 |
| The pinned source lives at `$FW`, and its cached archive hash equals the sha256 both locks record. | `~/.pub-cache/hosted-hashes/pub.dev/flutter_webrtc-1.6.0.sha256` | 2026-08-06 |
| The package manifest inside that directory declares `name: flutter_webrtc`, `version: 1.6.0`. | `$FW/pubspec.yaml:1,3` | 2026-08-06 |
| The macOS build copies under `$FW/macos/flutter_webrtc/Sources/flutter_webrtc/` are byte-identical to the `common/darwin/Classes/` originals for `LocalVideoTrack.{h,m}`, `VideoProcessingAdapter.{h,m}`, `FlutterRTCDesktopCapturer.m`, `FlutterRTCMediaStream.m` and `FlutterWebRTCPlugin.m`, so line references hold for either path. | `cmp` over the seven pairs | 2026-08-06 |

sha256 of the files the macOS build consumes, under
`$FW/macos/flutter_webrtc/Sources/flutter_webrtc/`:

| File | sha256 |
| --- | --- |
| `LocalVideoTrack.m` | `294bf2c001b854a1f21e495bb3798ca4bab2dcecf1140f981833ea8e8685b185` |
| `VideoProcessingAdapter.m` | `5500afb47648cd60fa4ebba45492dd50f4303346a2751cac5b591ed75d2c398f` |
| `FlutterRTCDesktopCapturer.m` | `a1a27b7801f0fb37bf91bf23cefe5889218de9bfce6e3683acbe736b904a8fa6` |
| `include/flutter_webrtc/LocalVideoTrack.h` | `3f8ce37274a3109bbd765c1ababa2a4a66c176040daa15b9412f5d9cd6977c7e` |
| `include/flutter_webrtc/VideoProcessingAdapter.h` | `e66c25b2b8a59b7fc1cf2d73ca173671c48933a95f92f4a93174540c93970255` |

## 2. VideoProcessingAdapter attach surface

| Claim | Evidence | Date |
| --- | --- | --- |
| `LocalVideoTrack`'s two-argument initializer `initWithTrack:videoProcessing:` accepts a `_Nullable` `VideoProcessingAdapter`. | `LocalVideoTrack.h:9-10` | 2026-08-06 |
| The `processing` property is nevertheless declared `_Nonnull`, so the nullability of an attached adapter is not expressible through it. | `LocalVideoTrack.h:14` | 2026-08-06 |
| `addProcessing:`/`removeProcessing:` are the public attach and detach entry points, taking an `ExternalVideoProcessingDelegate`. | `LocalVideoTrack.h:20-22` | 2026-08-06 |
| The single-argument initializer `initWithTrack:` passes `nil` for the adapter. | `LocalVideoTrack.m:21-23` | 2026-08-06 |
| `addProcessing:` and `removeProcessing:` forward to the `_processing` ivar with no nil check, so on a `nil`-adapter track both calls are silent no-ops. | `LocalVideoTrack.m:39-45` | 2026-08-06 |
| `mediaStreamGetTracks` rebuilds every video wrapper through that single-argument initializer, replacing any real adapter in `localTracks` with a `nil`-adapter wrapper. | `FlutterWebRTCPlugin.m:1901-1904` | 2026-08-06 |
| Dart `MediaStream.getTracks()` reads local lists only and issues no method call. | `lib/src/native/media_stream_impl.dart:36-38` | 2026-08-06 |
| Dart `MediaStream.getMediaTracks()` is the sole invoker of `mediaStreamGetTracks`. | `lib/src/native/media_stream_impl.dart:41-48` | 2026-08-06 |
| Babylon's camera open path uses `getTracks()`, and `apps/app/lib` contains no `getMediaTracks` caller. | `babylon/apps/app/lib/src/services/rtc.dart:121-134`; `grep -rn getMediaTracks apps/app/lib` returns nothing | 2026-08-06 |
| `getUserMedia`'s camera track is constructed with a real `VideoProcessingAdapter`. | `FlutterRTCMediaStream.m:529` | 2026-08-06 |
| `getDisplayMedia`'s screen track is likewise constructed with a real `VideoProcessingAdapter`. | `FlutterRTCDesktopCapturer.m:196` | 2026-08-06 |
| `VideoProcessingAdapter` holds one `os_unfair_lock` across the whole processor chain and the downstream `RTCVideoSource` delivery inside `capturer:didCaptureVideoFrame:`; work performed in `onFrame:` blocks frame delivery. | `VideoProcessingAdapter.m:45-53` (lock span `:47-52`) | 2026-08-06 |
| The same lock guards `addProcessing:` and `removeProcessing:`, so attach and detach block behind an in-flight frame. | `VideoProcessingAdapter.m:25-29,31-39` | 2026-08-06 |

## 3. getDesktopSources / `_captureSources` priming

| Claim | Evidence | Date |
| --- | --- | --- |
| `buildDesktopSourcesListWithTypes:forceReload:result:` replaces `_captureSources` with a fresh empty array on every call. | `FlutterRTCDesktopCapturer.m:355` | 2026-08-06 |
| It then appends window sources and afterwards screen sources, so window entries precede screen entries in the array. | `FlutterRTCDesktopCapturer.m:382-395` | 2026-08-06 |
| `getDesktopSources` calls it with `forceReload:YES`. | `FlutterRTCDesktopCapturer.m:229` | 2026-08-06 |
| `updateDesktopSources` calls it with `forceReload:NO`. | `FlutterRTCDesktopCapturer.m:289` | 2026-08-06 |
| `getSourceById:` resolves an ID only by linear scan of `_captureSources` and returns `nil` otherwise. | `FlutterRTCDesktopCapturer.m:339-348` | 2026-08-06 |
| `getDisplayMedia` fails with `No source found for id:` when `getSourceById:` returns `nil`, so capture of an ID absent from `_captureSources` is rejected. | `FlutterRTCDesktopCapturer.m:137-141` | 2026-08-06 |
| Consequence: an ID is capturable only while it sits in the array that the most recent `getDesktopSources`/`updateDesktopSources` populated. | `FlutterRTCDesktopCapturer.m:137-141,339-348,355` | 2026-08-06 |

## 4. Thumbnail gap on macOS

| Claim | Evidence | Date |
| --- | --- | --- |
| `getDesktopSources` emits per source only `id`, `name`, a `thumbnailSize` hardcoded to width 0 / height 0, and `type`. | `FlutterRTCDesktopCapturer.m:244-250` (`thumbnailSize` at `:247`) | 2026-08-06 |
| Its thumbnail render is commented out, and so is the `thumbnail` key, so the payload carries no image bytes. | `FlutterRTCDesktopCapturer.m:238-243,249` | 2026-08-06 |
| The Dart decoder assigns `thumbnail` only when the map carries that key, so `DesktopCapturerSource.thumbnail` is `null` after `getSources`. | `lib/src/native/desktop_capturer_impl.dart:15-19` | 2026-08-06 |
| The only macOS path that returns image bytes on demand is `getDesktopSourceThumbnail`, one source per call, and it returns `TIFFRepresentation`, not PNG. | `FlutterRTCDesktopCapturer.m:258-279` (encode at `:270`) | 2026-08-06 |
| The `desktopSourceAdded` event also carries `TIFFRepresentation` bytes with a 0×0 `thumbnailSize`, and empty `NSData` when the source has no image. | `FlutterRTCDesktopCapturer.m:406-419` | 2026-08-06 |

## 5. ScreenCaptureKit on the host

Host macOS 26.4 (25E246); the toolchain resolves `MacOSX26.5.sdk`. Header
lines below are in that SDK's `ScreenCaptureKit.framework/Headers/` and
`CoreGraphics.framework/Headers/`.

| Claim | Evidence | Date |
| --- | --- | --- |
| `SCShareableContent` is available from macOS 12.3, below the host version. | `SCShareableContent.h:139-140` | 2026-08-06 |
| `getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:` is the filtered snapshot entry point. | `SCShareableContent.h:162` | 2026-08-06 |
| A snapshot exposes `windows` and `displays` arrays. | `SCShareableContent.h:192,197` | 2026-08-06 |
| `SCWindow` carries `windowID`, `frame`, `title`, `onScreen` and `owningApplication`. | `SCShareableContent.h:56,61,66,76,81` | 2026-08-06 |
| `SCRunningApplication` carries `applicationName`. | `SCShareableContent.h:41` | 2026-08-06 |
| `SCDisplay` carries `displayID`, `width`, `height` and `frame`. | `SCShareableContent.h:96,101,106,111` | 2026-08-06 |
| `SCScreenshotManager` is available from macOS 14.0, below the host version. | `SCScreenshotManager.h:133-134` | 2026-08-06 |
| It offers `captureImageWithFilter:configuration:completionHandler:` (CGImage) and `captureSampleBufferWithFilter:configuration:completionHandler:`, both from macOS 14.0. | `SCScreenshotManager.h:152,143` | 2026-08-06 |
| `SCContentFilter` builds a display filter with `initWithDisplay:excludingWindows:` and a window filter with `initWithDesktopIndependentWindow:`. | `SCStream.h:146,154` | 2026-08-06 |
| `SCScreenshotManager`'s `captureScreenshotWithFilter:configuration:completionHandler:` and its `SCScreenshotConfiguration` require macOS 26.0, above a 14.0 floor. | `SCScreenshotManager.h:44-45,169` | 2026-08-06 |
| `CGPreflightScreenCaptureAccess` and `CGRequestScreenCaptureAccess` are available from macOS 10.15, matching the ux package's macOS deployment target. | `CGWindow.h:295,298` | 2026-08-06 |
| These surfaces compile against a 10.15 deployment target when guarded by `@available(macOS 12.3)` and `@available(macOS 14.0)`: `xcrun swiftc -target arm64-apple-macos10.15 -typecheck` succeeds on a probe referencing all of the above, and fails without the guards. | probe typecheck | 2026-08-06 |

## 6. `darwin/ux/Package.swift` target layout

| Claim | Evidence | Date |
| --- | --- | --- |
| The package is named `ux` and declares platforms iOS 13.0 and macOS 10.15. | `darwin/ux/Package.swift:23-28` | 2026-08-06 |
| It vends two library products, `ux` and `ux_extension`. | `darwin/ux/Package.swift:29-32` | 2026-08-06 |
| Its only external dependency is ZIPFoundation, up to next minor from 0.9.20. | `darwin/ux/Package.swift:33-37` | 2026-08-06 |
| Target `ux` covers `Sources/ux` in one Swift target for both platforms, depends on `ux_extension`, links ZIPFoundation on macOS only, and links AVFoundation, CoreMedia, CoreVideo plus platform-conditional IOKit/Intents/Photos/PhotosUI. | `darwin/ux/Package.swift:39-60` | 2026-08-06 |
| Target `ux_extension` covers `Sources/ux_extension` and builds with `-application-extension`. | `darwin/ux/Package.swift:61-65` | 2026-08-06 |
| The package declares no test target, and `darwin/ux/` holds only `Package.swift` and `Sources`. | `darwin/ux/Package.swift:38-71`; `ls darwin/ux` | 2026-08-06 |
| `Sources/ux` holds 52 files, 34 of which import Flutter; all 5 files of `Sources/ux_extension` import Flutter. | `grep -rl "import Flutter" darwin/ux/Sources/<target>` | 2026-08-06 |
| Consequence: both Swift targets import Flutter, so neither builds under bare `swift build`/`swift test`. | `darwin/ux/Package.swift:38-71` plus the import counts above | 2026-08-06 |
| `darwin/` contains no reference to WebRTC or flutter_webrtc. | `grep -rn "WebRTC\|flutter_webrtc" darwin/` returns nothing | 2026-08-06 |
| `darwin/` and `lib/` contain no reference to ScreenCaptureKit or `SCShareableContent`. | `grep -rn "ScreenCaptureKit\|SCShareableContent" darwin/ lib/` returns nothing | 2026-08-06 |
