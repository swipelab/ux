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
| `XKeyboard` — frame-accurate keyboard tracking + interactive dismiss | [lib/src/keyboard.dart](../lib/src/keyboard.dart) | [android/src/main/jni/keyboard_bridge.c](../android/src/main/jni/keyboard_bridge.c) | [darwin/ux/Sources/ux/iOS/KeyboardPlugin.swift](../darwin/ux/Sources/ux/iOS/KeyboardPlugin.swift) |
| `XSensors` — gyro / accelerometer over JNI/FFI | [lib/src/sensor.dart](../lib/src/sensor.dart) | [android/src/main/jni/sensor_bridge.c](../android/src/main/jni/sensor_bridge.c) | [darwin/ux/Sources/ux/iOS/SensorPlugin.swift](../darwin/ux/Sources/ux/iOS/SensorPlugin.swift) |
| `XCamera` — CameraX (Android) / AVCaptureSession (Apple). `XCameraController.cameraPermissionGranted()` queries authorization without prompting, microphone access or session creation. `requestCameraPermission()` prompts when permitted, otherwise opens camera/app Settings, and returns current authorization; re-query on foreground return. Hosts declare Android `android.permission.CAMERA`, Apple `NSCameraUsageDescription`, and macOS `com.apple.security.device.camera` in debug and release entitlements. | [lib/src/camera/](../lib/src/camera/) | [android/src/main/kotlin/io/swipelab/ux/camera/](../android/src/main/kotlin/io/swipelab/ux/camera/) | [darwin/ux/Sources/ux/Camera/](../darwin/ux/Sources/ux/Camera/) |
| `XAudioCapture` — live PCM from one source: mono 16 kHz Int16 frames of 320 samples (20 ms) plus an RMS level, over `ux/audio_capture` (+`/events`). `sources()` lists the hardware inputs the OS names — Core Audio devices by UID, `AVAudioSession` ports by uid, `AudioDeviceInfo` ids behind `mic:<id>` — plus one `playback` source where the platform taps its own output, and `start({sourceId})` opens it: omitted is the system's default microphone, one tap at a time, no mixing, and an id naming nothing fails `unknown_source`. A microphone is a *tap*, not an owner of the capture graph: Apple installs it on the `AVAudioEngine` input node and resamples the hardware format through an `AVAudioConverter`; Android reads an `AudioRecord` on `VOICE_COMMUNICATION`, which leaves the communication route to whoever holds it. It runs under the platform voice processing — Apple's `setVoiceProcessingEnabled`, Android's `AcousticEchoCanceler` — so what the device plays does not re-enter as local speech. Playback is that output, captured raw: macOS opens an audio-only `SCStream` under the screen-recording grant, excluding the host's own output so a dub cannot loop; Android 10+ opens an `AudioPlaybackCaptureConfiguration` under a media-projection consent the capture plugin asks for itself, held up by `AudioProjectionService` and unrelated to a screen share's `ScreenShareService`; iOS lists no playback source at all. The level is computed in Dart from the samples so both platforms report the same number. `state` (`idle`/`running`/`interrupted`) is the single source of truth and never resumes on its own — iOS drops to `interrupted` on `AVAudioSession` interruption (call, Siri) and on `oldDeviceUnavailable` route changes, Android on `AudioRecordingConfiguration.isClientSilenced` (API 29+) or a failed `AudioRecord.read`, and both on the engine's configuration-change notification. macOS has no `AVAudioSession`, so there the configuration change (default input swapped or removed) is the only interruption signal; a playback tap drops to `interrupted` when the system ends the stream or the projection. Hosts declare their own access: `RECORD_AUDIO`, `NSMicrophoneUsageDescription`, and `com.apple.security.device.audio-input` plus `com.apple.security.screen-capture` for a sandboxed macOS playback tap. Consumer: transcript.chat's live captioning, reading the mic while flutter_webrtc holds it | [lib/src/audio/x_audio_capture.dart](../lib/src/audio/x_audio_capture.dart) | [android/.../AudioCapturePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/AudioCapturePlugin.kt) | [darwin/ux/Sources/ux/Audio/AudioCapturePlugin.swift](../darwin/ux/Sources/ux/Audio/AudioCapturePlugin.swift) |
| `XAudioSink` — push-based playback of mono 16 kHz Int16 PCM over `ux/audio_sink` (+`/events`): `enqueue(Int16List)` appends a chunk and opens the output on the first one, so a stream is audible long before it ends; `flush()` silences and empties the queue — including chunks Dart has not handed over yet, which a generation counter drops on their way to the channel — and releases the output; `drained` fires when the queue plays out, leaving the output open so the next chunk of a conversation skips the device warm-up. A *writer* on the output, not an owner of the route: Apple schedules converted buffers on an `AVAudioPlayerNode` connected to the main mixer, which resamples to the hardware rate, and on iOS only widens the shared `AVAudioSession` category to include playback with no added options, so a call keeps its `.voiceChat` mode and speaker choice; Android streams into an `AudioTrack` on `USAGE_MEDIA` + `CONTENT_TYPE_SPEECH` and never requests audio focus, so it neither claims the communication route nor ducks what is already playing — a consumer wanting exclusive playback asks for focus itself. `state` (`idle`/`playing`/`interrupted`) never resumes on its own: iOS drops to `interrupted` on an `AVAudioSession` interruption, macOS when a configuration change leaves the engine stopped, Android on a failed `AudioTrack.write`. Consumer: transcript.chat's dubbing, playing a TTS byte stream while a call holds the microphone | [lib/src/audio/x_audio_sink.dart](../lib/src/audio/x_audio_sink.dart) | [android/.../AudioSinkPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/AudioSinkPlugin.kt) | [darwin/ux/Sources/ux/Audio/AudioSinkPlugin.swift](../darwin/ux/Sources/ux/Audio/AudioSinkPlugin.swift) |
| `XScanner` — ZXing QR scanner (Android) / VNDetect (Apple) | [lib/src/scanner.dart](../lib/src/scanner.dart) | [android/src/main/kotlin/io/swipelab/ux/ScannerPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/ScannerPlugin.kt) | [darwin/ux/Sources/ux/iOS/ScannerPlugin.swift](../darwin/ux/Sources/ux/iOS/ScannerPlugin.swift) |
| `XVideoPlayer` — ExoPlayer (Android) / AVPlayer (Apple) | [lib/src/video/](../lib/src/video/) | [android/src/main/kotlin/io/swipelab/ux/video/](../android/src/main/kotlin/io/swipelab/ux/video/) | [darwin/ux/Sources/ux/Video/](../darwin/ux/Sources/ux/Video/) |
| `XVideoExporter` — trim / mute / crop-rotate-flip video export: Media3 Transformer (Android) / AVAssetExportSession passthrough remux with re-encode fallback, `AVAssetReader`/`Writer` + per-frame `AVMutableVideoComposition` for the transform path (Apple). Trim+mute alone stays a passthrough remux; a crop/rotate/mirror request re-encodes at a telegram bitrate tier (480/640/848/1280/1920 · 400–6600 kbps H.264+AAC). Geometry is a caller-supplied source→output affine (`transform3x3` + `outWidth`/`outHeight`) in upright **native source pixels**, applied verbatim so the output matches the caller's on-screen preview. An optional `overlayPath` (transparent PNG at upright source dims, requires `transform`) is composited over each frame BEFORE the affine — caller-drawn paint strokes ride the crop. Session API: progress stream + cancel over `ux/video/export` (+`/events`). Consumer: banlu's compose video editing (telegram-parity trim/mute/crop). | [lib/src/video/x_video_exporter.dart](../lib/src/video/x_video_exporter.dart) | [android/.../video/VideoExporterPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/video/VideoExporterPlugin.kt) | [darwin/ux/Sources/ux/Video/VideoExporterPlugin.swift](../darwin/ux/Sources/ux/Video/VideoExporterPlugin.swift) |
| `XNotifications` — OS notifications: show / cancel / tap / authorization | [lib/src/notifications/](../lib/src/notifications/) | [android/.../NotificationsPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/NotificationsPlugin.kt) | [darwin/ux/Sources/ux/macOS/NotificationsPlugin.swift](../darwin/ux/Sources/ux/macOS/NotificationsPlugin.swift) (macOS only) |
| `XWindow` — host focus state (`focused`, macOS + Android) and `keepAwake(bool)`, the screen hold a call keeps while nobody touches the device. iOS disables the idle timer, Android sets `FLAG_KEEP_SCREEN_ON` on the activity window, macOS takes a `kIOPMAssertionTypeNoDisplaySleep` `IOPMAssertion`. Releasing is part of the contract, since a hold nobody drops keeps a display lit until the battery is flat: Android clears the flag when the activity detaches and drops the hold itself when the engine does, iOS clears the flag when the app leaves the foreground and re-applies it on return, macOS releases on `NSApplicationWillTerminate` and when the engine releases the plugin. All three are process-scoped, so a crash releases them too. Consumer: transcript.chat's call screen | [lib/src/window/](../lib/src/window/) | [android/.../WindowPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/WindowPlugin.kt) | [darwin/.../macOS/WindowPlugin.swift](../darwin/ux/Sources/ux/macOS/WindowPlugin.swift) · [darwin/.../iOS/WindowPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/WindowPlugin+iOS.swift) |
| `XScreenSources` — the displays and windows a screen-share picker offers, taken as one snapshot over `ux/screen_sources`: `list(allowedDisplayIds:, allowedWindowIds:, thumbnailWidth:, thumbnailHeight:)` intersects the caller's allow-sets with what is on screen and returns each survivor as an id, kind, title, owning application, source pixel dimensions, and an aspect-fit PNG thumbnail. The caller owns enumeration order: it passes the ids its capture stack reported and presents exactly the returned snapshot, whose ids go straight back to capture. A source whose thumbnail fails to render comes back with a null `thumbnailPng`, so one bad window never costs the picker its list; `thumbnail_failed` means no requested source rendered at all. `list` never prompts — `hasPermission` / `requestPermission` are explicit, and the caller drives them before opening a picker. `captureMode` names how a family chooses a capture — `pickerDriven` on macOS, `consentDriven` on Android and iOS where the system consent surface both asks and chooses, null elsewhere — and is readable independently of `supported`, so a consumer builds the right flow per family without platform checks of its own. A call the family's mode has no role for throws `unsupported` before the channel: `list` and the permission pair off `pickerDriven`, `startShare` / `stopShare` off `consentDriven`. Those two serve two arms. On Android, `startShare(notificationTitle:, notificationText:)` runs `ScreenShareService`, the `mediaProjection` foreground service Android grants `createVirtualDisplay` only while it is up and grants itself only once the projection consent is held — so the bracket belongs between the consumer's consent call and its capture start, and `stopShare()` drops it, as does the engine detaching. ux declares the service plus `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PROJECTION` in its own manifest, which merges into the host app, and the ongoing notification carries the host's `io.swipelab.ux.notification_icon` meta-data icon; a start the platform refuses for want of consent throws `permission_denied`, any other refusal `service_start_failed`. On iOS the capture is ReplayKit's in-app recorder, which the consumer's stack starts through `getDisplayMedia`'s `RPScreenRecorder` path — the alert it raises is the consent, the frames arrive in-process, and what it captures is the host app's own display while the app is in front, not the device — capture past the app is a broadcast upload extension, which this arm does not build, so no broadcast upload extension, `Info.plist` key or entitlement takes part. iOS asks for no hold around that capture, so `startShare` carries `RPScreenRecorder`'s arbitration instead — a refusal while the app is not in front, a mirrored display is attached, or another recorder holds the screen, raised as `service_start_failed` before the consumer asks for a track that would never produce a frame — the notification arguments have no role against the system's own recording indicator, and `stopShare` holds nothing to drop and succeeds. Consent and capture themselves are the consumer's, over its own capture stack. `supported` is the platform family that serves the calls (macOS, Android, iOS), `available()` the whole capability including the OS version — macOS 14, Android 10, where the `mediaProjection` service type exists, iOS 13, where the answer is ReplayKit's own and false while the app is not in front, a mirrored display is attached, or another recorder holds the screen. Thumbnail dimensions are bounded 1..4096 in Dart and throw `ArgumentError` before the channel, and a reply that does not match the wire shape throws `invalid_response` naming the offending field. `XScreenSourcesBackend.instance` is settable, and `package:ux/testing.dart`'s `FakeXScreenSourcesBackend` scripts snapshots, permission flows and failures without a host. Consumer: transcript.chat's screen-share picker | [lib/src/screen/](../lib/src/screen/) | [android/.../screen/](../android/src/main/kotlin/io/swipelab/ux/screen/) | [darwin/.../macOS/ScreenSources/](../darwin/ux/Sources/ux/macOS/ScreenSources/) · [darwin/.../iOS/ScreenSourcesPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/ScreenSourcesPlugin+iOS.swift) |
| `XCameraEffects` — None / Blur / Dim behind the person on the outgoing camera track, over `ux/camera_effects` (+`/events`): `setEffect(trackId, effect)` hands the local video track to the native processor and `clear()` gives it back its own frames. One track carries an effect at a time, so `clear` names none — and `setEffect(..., none)` is that same clear. Commands serialize in Dart, each carrying a generation allocated when the queue reaches the wire; the last generation the platform took is the floor under which arriving status describes a retired effect and is dropped. `status` (`idle`/`applying`/`active`/`failed`) is the native processor's account of the frames — Dart authors only the `idle` a successful `clear` settles, and `active` means composited frames are flowing. A command reports its own outcome by throwing `XCameraEffectsException` with the platform's code (`track_not_found`, `track_not_processable`, `initialization_failed`, `integration_unavailable` for a missing bridge, Dart's own `invalid_response` for a reply off the wire shape); a fault arriving after a command succeeded comes as a `failed` status carrying `processing_failed`. The event stream is subscribed on the first wire call that succeeds, which is also what proves a native handler is there, so a host without the bridge answers `integration_unavailable` and stays silent. `supported` is the platform family (macOS, iOS, Android), `available()` the whole capability including the OS version and the installed bridge. `XCameraEffectsBackend.instance` is settable, and `package:ux/testing.dart`'s `FakeXCameraEffectsBackend` scripts command results and drives status without a host. The host app hands `ux` its camera stack through `CameraEffects.install(_:)`: a `CameraEffectsBridge` looks a track up by id, takes a `(CameraEffectsFrame) -> CameraEffectsFrame` processing callback and removes it by identity, and uninstalling reports a live attachment failed at that moment. `ux_macos_core`'s `CameraEffectsService` owns everything else — one effected track, commands one at a time, an attach that withholds its reply until the first frame reaches the processor or 750 ms pass (`track_not_processable`), a second 750 ms window from that frame (or from an accepted same-track switch) to the first composited output, whose expiry detaches the processor and retracts to `idle`, `active` emitted on the first composited outcome and one `processing_failed` per activation record on the first substituted outcome after it (a same-track switch re-arms both), outcomes stamped with the processor that produced them so one arriving from a retired processor neither activates nor fails, the generation each status carries, and the `currentStatus` the event channel seeds on listen — so the plugin only marshals. `ux_macos_core/CameraEffects` is also home to `CameraEffectCompositor` and its bounded `PixelBufferPool`: one Core Image graph per effect reads the input through its crop, scales to the adapted size, composites the person over the blurred/dimmed background when a mask arrives (whole-frame effect without one), and fails closed to the last-good effected frame or a prepared black one — never the raw input. `PersonMaskProducer` keeps that mask current: an eligible frame's crop is downscaled into a ux-owned 256x144 buffer and handed to one serial queue running `VisionPersonSegmenter` (macOS 12+ / iOS 15+, Vision's `.fast` level, whose 256x192 grid the compositor stretches onto the crop), and the newest generation-matched result is published for the compositor to pull. A frame is copied only when no inference is in flight, submissions are capped at 15/s and widen to the last published inference's latency, and `reset()` retires every mask and submission without waiting on Vision. `XCameraFrameProcessor` ties the three together — every frame feeds the producer it owns and composites with the newest published mask, the composite wrapped in an `os_signpost` interval, a mask rejection recorded but never emitted, and `retire()` resetting the producer — and `XCameraFrameProcessors` (returned by `CameraEffectHost.processors()` on macOS 12+ / iOS 15+) builds one per effect. Android carries the same stack in `io.swipelab.ux.camera.effects`, where the host installs its camera through `CameraEffects.install(bridge)`: the same service state machine, a `CameraEffectCompositor` rendering the frame's I420 planes on the CPU (box-blur or dim on a downscaled grid, the person blended back over it, fail-closed to the last-good effected frame or black out of a bounded `FrameBufferPool`), and a `PersonMaskProducer` over `MlKitPersonSegmenter` — ML Kit selfie segmentation in stream mode, its model inside the artifact — on the same 256x144 input and 15/s cap, the input carrying the frame's rotation so the model reads an upright scene and the mask it answers on that upright grid mapped back onto the input's own. `CameraThermalCadence` is the floor under that cap: `PowerManager`'s thermal status at light or above, held ten unbroken seconds, doubles the submission interval, and a status below it returns the target on the next submission — the listener is API 29, so hosts below it hold the fixed rate. `CameraEffectProcessors` pairs one of each per effect into a `CompositingEffectProcessor` whose `retire()` closes the producer and gives up the compositor's fallback claim; a frame still arriving takes the ordinary path and publishes a fresh whole-frame effect of itself. Direction names the owner across `CameraTrackBridging`: the host transfers one `CameraFrame` per representable frame and the core closes it exactly once before `processing` returns, `processing` answers a `PublishedFrame` over planes the core holds that the host closes before its capture callback returns — flutter_webrtc releases nothing a processor returns, so the Android host copies the publication into memory of its own and publishes the copy, and pixels are given up only by closing a frame — a frame the bridge cannot represent reaches no `CameraFrame` and no `processing` call. Consumer: transcript.chat's call background control | [lib/src/camera/x_camera_effects.dart](../lib/src/camera/x_camera_effects.dart) | [android/.../camera/effects/](../android/src/main/kotlin/io/swipelab/ux/camera/effects/) | [darwin/ux/Sources/ux_macos_core/CameraEffects/](../darwin/ux/Sources/ux_macos_core/CameraEffects/), [darwin/ux/Sources/ux/CameraEffects/](../darwin/ux/Sources/ux/CameraEffects/) |
| `XSecureStore` — string secrets by key over `ux/secure_store`: `read` / `write` / `delete`, where a missing key reads null, a write replaces, and deleting a key that holds nothing succeeds. Apple keeps one `kSecClassGenericPassword` Keychain item per key, service-scoped to the host bundle identifier and `kSecAttrSynchronizable` false so nothing reaches iCloud; iOS items are `kSecAttrAccessibleAfterFirstUnlock`, and macOS uses the file-based keychain because the data-protection keychain there answers `errSecMissingEntitlement` without a keychain-access-group entitlement. Android seals values with an AndroidKeyStore AES-256-GCM key — key material stays in the TEE, ciphertext (IV ++ sealed bytes, base64) sits in a private SharedPreferences file, key names in the clear. API 22 and below answers `unsupported` because Keystore AES requires API 23. Commands are serialized in Dart, so a read after a write observes it; neither side logs a key or a value. Consumer: transcript.chat's session token | [lib/src/secure_store/x_secure_store.dart](../lib/src/secure_store/x_secure_store.dart) | [android/.../SecureStorePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/SecureStorePlugin.kt) | [darwin/.../SecureStore/SecureStorePlugin.swift](../darwin/ux/Sources/ux/SecureStore/SecureStorePlugin.swift) |
| `XUrl` — URL / phone / email detection in text (FFI to `NSDataDetector` / `Patterns.WEB_URL`), an allowlisted `launch(url)` over `ux/url`, and `openAppSettings()`, the recovery link offered after a permission is denied. iOS opens `UIApplication.openSettingsURLString` and Android `ACTION_APPLICATION_DETAILS_SETTINGS` for the host package, both this app's own page; macOS has no per-app page, so it opens System Settings' Privacy & Security pane, where camera, microphone and screen-recording access is listed by app | [lib/src/url.dart](../lib/src/url.dart) | [android/.../UrlPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/UrlPlugin.kt) · [android/src/main/jni/url_detect.cpp](../android/src/main/jni/url_detect.cpp) | [darwin/.../iOS/UrlPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/UrlPlugin+iOS.swift) · [darwin/.../macOS/UrlPlugin+macOS.swift](../darwin/ux/Sources/ux/macOS/UrlPlugin+macOS.swift) · [darwin/.../ux_url_detect/url_detect.m](../darwin/ux/Sources/ux_url_detect/url_detect.m) |
| `XFiles.videoThumbnail` — single-frame poster extract, optionally BAKED: `transform3x3` + `outWidth`/`outHeight` (the exporter's upright-source-px→output-px affine contract) + `overlayPath` (strokes PNG composited before the affine) + `maxLongest` (final thumb cap) run entirely in the native software rasteriser (Android `Bitmap`/`Canvas`, Apple `CGContext`) and return the finished PNG. Callers must NOT re-rasterise the frame through Flutter's `Picture.toImage` — it silently returns blank/black frames in some device states (Huawei, after sleep/wake cycles; ~50% of calls). Consumer: banlu's send-time bubble thumb. | [lib/src/file.dart](../lib/src/file.dart) | [android/.../FilePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/FilePlugin.kt) | [darwin/ux/Sources/ux/iOS/FilePlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/FilePlugin+iOS.swift) · [darwin/ux/Sources/ux/macOS/FilePlugin+macOS.swift](../darwin/ux/Sources/ux/macOS/FilePlugin+macOS.swift) |
| `XAppGroup` — Apple App Group container lookup (`containerPath(groupId)` → `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, null when the target isn't entitled). Consumer: banlu's data root, shared with its share extension. No Android analogue — the app and its share activity are one process | [lib/src/app_group.dart](../lib/src/app_group.dart) | n/a | [darwin/ux/Sources/ux_extension/AppGroupPlugin.swift](../darwin/ux/Sources/ux_extension/AppGroupPlugin.swift) |
| `XVideoProbe` — one native round-trip describing a video file: upright display dimensions, duration, and a poster frame. No player and no texture registry, which is what lets an **app extension** host it — see the packaging note below. Apple backs it with `AVAsset` + `AVAssetImageGenerator`, Android with a single `MediaMetadataRetriever` (dimensions from the width/height metadata swapped by `METADATA_KEY_VIDEO_ROTATION`, poster from `getFrameAtTime`). A file with no video track reports null; a file whose frame won't decode still reports dimensions and duration. Consumer: banlu's share surface on both platforms, whose picker needs a video placeholder without spinning `XVideoPlayer` | [lib/src/video/x_video_probe.dart](../lib/src/video/x_video_probe.dart) | [android/.../VideoProbePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/VideoProbePlugin.kt) | [darwin/ux/Sources/ux_extension/VideoProbePlugin.swift](../darwin/ux/Sources/ux_extension/VideoProbePlugin.swift) |
| `XImageProbe` — upright dimensions and a downscaled PNG of an image file, in one native round-trip that **never materialises the full-resolution bitmap**. Flutter's own route (`instantiateImageCodec` over the bytes) costs 4 bytes per *source* pixel even to read the intrinsic size or make a 200px thumbnail — ~190 MB for a 48-megapixel photo, several times what an **app extension** is allowed. Apple reads the header with `CGImageSourceCopyPropertiesAtIndex` and renders through `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceCreateThumbnailWithTransform` applies the EXIF orientation, so reported dimensions and pixels agree); Android measures with `inJustDecodeBounds` and decodes subsampled via `inSampleSize`, then rotates by the `ExifInterface` orientation. Both allocate for the *output*. Lives in `ux_extension` for the same reason `XVideoProbe` does. `supported` is false off iOS/macOS/Android, where the caller keeps its own decode path. Consumer: banlu's outgoing-media preview (inline thumb + `thumbFile`), on every host | [lib/src/image/x_image_probe.dart](../lib/src/image/x_image_probe.dart) | [android/.../ImageProbePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/ImageProbePlugin.kt) | [darwin/ux/Sources/ux_extension/ImageProbePlugin.swift](../darwin/ux/Sources/ux_extension/ImageProbePlugin.swift) |
| `XShortcuts` — per-conversation **Direct Share** targets in the OS share sheet. One Dart surface, `donate(targets, category)` / `clear()`, over two unrelated OS mechanisms. **Android**: dynamic shortcuts — the caller's ordered top-N replaces the set wholesale (`ShortcutManagerCompat.setDynamicShortcuts`, capped at `getMaxShortcutCountPerActivity`); each is long-lived, carries a `Person` + `LocusIdCompat` keyed by the caller's id, an adaptive-bitmap icon decoded from `iconPath`, and the caller's `category` — which the consuming app's `share-targets.xml` must also declare. The shortcut's own intent (a launcher tap) is the package launch intent; the share sheet instead routes to the `<share-target>` activity with `EXTRA_SHORTCUT_ID`. A shortcut the user pinned to their home screen is not the app's to delete, so `clear()` removes the dynamic set and *disables* whatever is pinned (`FLAG_MATCH_PINNED` → `disableShortcuts`) — otherwise a logout would leave the previous account's names and faces sitting on the launcher; `donate` re-enables the ids it publishes, so signing back in restores them. **iOS**: SiriKit donation — one `INSendMessageIntent` per target wrapped in an outgoing `INInteraction`, `conversationIdentifier` = the caller's id (what the consuming share extension reads back off `NSExtensionContext.intent`), `speakableGroupName` = the label, `INImage` from `iconPath`, and `INInteraction.identifier` = the caller's id so a re-donation replaces rather than accumulates. Donations are ranked by recency, so the list is donated tail-first; `clear()` is `INInteraction.delete(with:)` on the plugin's own group identifier, which is also what keeps `category` an Android-only argument. **macOS**: `supported` is false — AppKit's share menu has no conversation suggestions. Consumer: banlu's dialog list, donating its four most recent conversations | [lib/src/shortcuts.dart](../lib/src/shortcuts.dart) | [android/.../ShortcutsPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/ShortcutsPlugin.kt) | [darwin/ux/Sources/ux/iOS/ShortcutsPlugin.swift](../darwin/ux/Sources/ux/iOS/ShortcutsPlugin.swift) (iOS only) |
| `XFile`, navi — see source | [lib/src/](../lib/src/) | mixed | mixed |

### Apple packaging — two SPM products

`darwin/ux` vends `ux` and `ux_extension`. `ux_extension`
([Sources/ux_extension/](../darwin/ux/Sources/ux_extension/):
`AppGroupPlugin`, `CryptoPlugin`, `VideoProbePlugin`) is everything an **app
extension** may link:
it is compiled `-application-extension`, so `UIApplication` and friends fail to
compile there. `ux` cannot be linked from an extension at all — keyboard,
gallery, camera and url all reach for `UIApplication.shared`. `ux` depends on
`ux_extension` and declares its plugins' `NativePlugin` conformances
([Sources/ux/ExtensionPlugins.swift](../darwin/ux/Sources/ux/ExtensionPlugins.swift)),
so `XPlugin` registers them for the app exactly as before; an extension host
links `ux_extension` alone and registers what it needs itself. Consumer:
banlu's iOS share extension.

Keyboard, sensor, and URL-detect talk to Dart through `DynamicLibrary.process()`.
The host app's release strip keeps global symbols (`STRIP_STYLE = non-global`).
The Swift entry points are `@_used`, so dead-stripping keeps them; the `ux` target
enables `SymbolLinkageMarkers` for that attribute.

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
[darwin/ux/Sources/ux/Video/VideoPlayerInstance.swift](../darwin/ux/Sources/ux/Video/VideoPlayerInstance.swift).

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
