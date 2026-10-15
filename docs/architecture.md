# ux — architecture

This doc maps the load-bearing modules in the `ux` Flutter package: where
each lives, what it owns, and which native pieces back it on each
platform. Banlu is the primary consumer; everything here is meant to be
reusable across other Flutter apps that depend on `ux`.

Conventions:

* Source paths are anchored at the package root (e.g. `lib/src/...`).
* Native paths use `android/...`, `darwin/...` (shared
  iOS+macOS sources) or `ios/` / `macos/` (platform-specific), and
  `windows/...`.
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
| `XVideoPlayer` — ExoPlayer (Android) / AVPlayer (Apple) / Media Foundation's Media Engine (Windows, [windows/video_player_plugin.cpp](../windows/video_player_plugin.cpp); see *Video pipeline (Windows)*) | [lib/src/video/](../lib/src/video/) | [android/src/main/kotlin/io/swipelab/ux/video/](../android/src/main/kotlin/io/swipelab/ux/video/) | [darwin/ux/Sources/ux/Video/](../darwin/ux/Sources/ux/Video/) |
| `XVideoExporter` — trim / mute / crop-rotate-flip video export: Media3 Transformer (Android) / AVAssetExportSession passthrough remux with re-encode fallback, `AVAssetReader`/`Writer` + per-frame `AVMutableVideoComposition` for the transform path (Apple) / Media Foundation re-encode of every request (Windows, [windows/video_exporter_plugin.cpp](../windows/video_exporter_plugin.cpp); see *Video frames and export (Windows)*). Trim+mute alone stays a passthrough remux where the platform has one; a crop/rotate/mirror request re-encodes at a telegram bitrate tier (480/640/848/1280/1920 · 400–6600 kbps H.264+AAC). Geometry is a caller-supplied source→output affine (`transform3x3` + `outWidth`/`outHeight`) in upright **native source pixels**, applied verbatim so the output matches the caller's on-screen preview. An optional `overlayPath` (transparent PNG at upright source dims, requires `transform`) is composited over each frame BEFORE the affine — caller-drawn paint strokes ride the crop. Session API: progress stream + cancel over `ux/video/export` (+`/events`). Consumer: banlu's compose video editing (telegram-parity trim/mute/crop). | [lib/src/video/x_video_exporter.dart](../lib/src/video/x_video_exporter.dart) | [android/.../video/VideoExporterPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/video/VideoExporterPlugin.kt) | [darwin/ux/Sources/ux/Video/VideoExporterPlugin.swift](../darwin/ux/Sources/ux/Video/VideoExporterPlugin.swift) |
| `XNotifications` — OS notifications: show / cancel / tap / authorization. On Windows, toasts through [windows/notifications_plugin.cpp](../windows/notifications_plugin.cpp); see *Notifications + window focus* | [lib/src/notifications/](../lib/src/notifications/) | [android/.../NotificationsPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/NotificationsPlugin.kt) | [darwin/ux/Sources/ux/macOS/NotificationsPlugin.swift](../darwin/ux/Sources/ux/macOS/NotificationsPlugin.swift) (macOS only) |
| `XWindow` — host focus state (`focused`, macOS, Android and Windows) and `keepAwake(bool)`, the screen hold a call keeps while nobody touches the device. iOS disables the idle timer, Android sets `FLAG_KEEP_SCREEN_ON` on the activity window, macOS takes a `kIOPMAssertionTypeNoDisplaySleep` `IOPMAssertion`, and Windows ([windows/window_plugin.cpp](../windows/window_plugin.cpp)) sets `ES_CONTINUOUS \| ES_DISPLAY_REQUIRED` on the platform thread with `SetThreadExecutionState`. Releasing is part of the contract, since a hold nobody drops keeps a display lit until the battery is flat: Android clears the flag when the activity detaches and drops the hold itself when the engine does, iOS clears the flag when the app leaves the foreground and re-applies it on return, macOS releases on `NSApplicationWillTerminate` and when the engine releases the plugin, and Windows releases on the top-level window's `WM_DESTROY`. All four are process-scoped, so a crash releases them too. Each focus event logs `focused: <bool>` at info level, tagged `window`. Consumer: transcript.chat's call screen | [lib/src/window/](../lib/src/window/) | [android/.../WindowPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/WindowPlugin.kt) | [darwin/.../macOS/WindowPlugin.swift](../darwin/ux/Sources/ux/macOS/WindowPlugin.swift) · [darwin/.../iOS/WindowPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/WindowPlugin+iOS.swift) |
| `XScreenSources` — the displays and windows a screen-share picker offers, taken as one snapshot over `ux/screen_sources`: `list(allowedDisplayIds:, allowedWindowIds:, thumbnailWidth:, thumbnailHeight:)` intersects the caller's allow-sets with what is on screen and returns each survivor as an id, kind, title, owning application, source pixel dimensions, and an aspect-fit PNG thumbnail. The caller owns enumeration order: it passes the ids its capture stack reported and presents exactly the returned snapshot, whose ids go straight back to capture. A source whose thumbnail fails to render comes back with a null `thumbnailPng`, so one bad window never costs the picker its list; `thumbnail_failed` means no requested source rendered at all. `list` never prompts — `hasPermission` / `requestPermission` are explicit, and the caller drives them before opening a picker. `captureMode` names how a family chooses a capture — `pickerDriven` on macOS, `consentDriven` on Android and iOS where the system consent surface both asks and chooses, null elsewhere — and is readable independently of `supported`, so a consumer builds the right flow per family without platform checks of its own. A call the family's mode has no role for throws `unsupported` before the channel: `list` and the permission pair off `pickerDriven`, `startShare` / `stopShare` off `consentDriven`. Those two serve two arms. On Android, `startShare(notificationTitle:, notificationText:)` runs `ScreenShareService`, the `mediaProjection` foreground service Android grants `createVirtualDisplay` only while it is up and grants itself only once the projection consent is held — so the bracket belongs between the consumer's consent call and its capture start, and `stopShare()` drops it, as does the engine detaching. ux declares the service plus `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PROJECTION` in its own manifest, which merges into the host app, and the ongoing notification carries the host's `io.swipelab.ux.notification_icon` meta-data icon; a start the platform refuses for want of consent throws `permission_denied`, any other refusal `service_start_failed`. On iOS the capture is ReplayKit's in-app recorder, which the consumer's stack starts through `getDisplayMedia`'s `RPScreenRecorder` path — the alert it raises is the consent, the frames arrive in-process, and what it captures is the host app's own display while the app is in front, not the device — capture past the app is a broadcast upload extension, which this arm does not build, so no broadcast upload extension, `Info.plist` key or entitlement takes part. iOS asks for no hold around that capture, so `startShare` carries `RPScreenRecorder`'s arbitration instead — a refusal while the app is not in front, a mirrored display is attached, or another recorder holds the screen, raised as `service_start_failed` before the consumer asks for a track that would never produce a frame — the notification arguments have no role against the system's own recording indicator, and `stopShare` holds nothing to drop and succeeds. Consent and capture themselves are the consumer's, over its own capture stack. `supported` is the platform family that serves the calls (macOS, Android, iOS), `available()` the whole capability including the OS version — macOS 14, Android 10, where the `mediaProjection` service type exists, iOS 13, where the answer is ReplayKit's own and false while the app is not in front, a mirrored display is attached, or another recorder holds the screen. Thumbnail dimensions are bounded 1..4096 in Dart and throw `ArgumentError` before the channel, and a reply that does not match the wire shape throws `invalid_response` naming the offending field. `XScreenSourcesBackend.instance` is settable, and `package:ux/testing.dart`'s `FakeXScreenSourcesBackend` scripts snapshots, permission flows and failures without a host. Consumer: transcript.chat's screen-share picker | [lib/src/screen/](../lib/src/screen/) | [android/.../screen/](../android/src/main/kotlin/io/swipelab/ux/screen/) | [darwin/.../macOS/ScreenSources/](../darwin/ux/Sources/ux/macOS/ScreenSources/) · [darwin/.../iOS/ScreenSourcesPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/ScreenSourcesPlugin+iOS.swift) |
| `XCameraEffects` — None / Blur / Dim behind the person on the outgoing camera track, over `ux/camera_effects` (+`/events`): `setEffect(trackId, effect)` hands the local video track to the native processor and `clear()` gives it back its own frames. One track carries an effect at a time, so `clear` names none — and `setEffect(..., none)` is that same clear. Commands serialize in Dart, each carrying a generation allocated when the queue reaches the wire; the last generation the platform took is the floor under which arriving status describes a retired effect and is dropped. `status` (`idle`/`applying`/`active`/`failed`) is the native processor's account of the frames — Dart authors only the `idle` a successful `clear` settles, and `active` means composited frames are flowing. A command reports its own outcome by throwing `XCameraEffectsException` with the platform's code (`track_not_found`, `track_not_processable`, `initialization_failed`, `integration_unavailable` for a missing bridge, Dart's own `invalid_response` for a reply off the wire shape); a fault arriving after a command succeeded comes as a `failed` status carrying `processing_failed`. The event stream is subscribed on the first wire call that succeeds, which is also what proves a native handler is there, so a host without the bridge answers `integration_unavailable` and stays silent. `supported` is the platform family (macOS, iOS, Android), `available()` the whole capability including the OS version and the installed bridge. `XCameraEffectsBackend.instance` is settable, and `package:ux/testing.dart`'s `FakeXCameraEffectsBackend` scripts command results and drives status without a host. The host app hands `ux` its camera stack through `CameraEffects.install(_:)`: a `CameraEffectsBridge` looks a track up by id, takes a `(CameraEffectsFrame) -> CameraEffectsFrame` processing callback and removes it by identity, and uninstalling reports a live attachment failed at that moment. `ux_macos_core`'s `CameraEffectsService` owns everything else — one effected track, commands one at a time, an attach that withholds its reply until the first frame reaches the processor or 750 ms pass (`track_not_processable`), a second 750 ms window from that frame (or from an accepted same-track switch) to the first composited output, whose expiry detaches the processor and retracts to `idle`, `active` emitted on the first composited outcome and one `processing_failed` per activation record on the first substituted outcome after it (a same-track switch re-arms both), outcomes stamped with the processor that produced them so one arriving from a retired processor neither activates nor fails, the generation each status carries, and the `currentStatus` the event channel seeds on listen — so the plugin only marshals. `ux_macos_core/CameraEffects` is also home to `CameraEffectCompositor` and its bounded `PixelBufferPool`: one Core Image graph per effect reads the input through its crop, scales to the adapted size, composites the person over the blurred/dimmed background when a mask arrives (whole-frame effect without one), and fails closed to the last-good effected frame or a prepared black one — never the raw input. `PersonMaskProducer` keeps that mask current: an eligible frame's crop is downscaled into a ux-owned 256x144 buffer and handed to one serial queue running `VisionPersonSegmenter` (macOS 12+ / iOS 15+, Vision's `.fast` level, whose 256x192 grid the compositor stretches onto the crop), and the newest generation-matched result is published for the compositor to pull. A frame is copied only when no inference is in flight, submissions are capped at 15/s and widen to the last published inference's latency, and `reset()` retires every mask and submission without waiting on Vision. `XCameraFrameProcessor` ties the three together — every frame feeds the producer it owns and composites with the newest published mask, the composite wrapped in an `os_signpost` interval, a mask rejection recorded but never emitted, and `retire()` resetting the producer — and `XCameraFrameProcessors` (returned by `CameraEffectHost.processors()` on macOS 12+ / iOS 15+) builds one per effect. Android carries the same stack in `io.swipelab.ux.camera.effects`, where the host installs its camera through `CameraEffects.install(bridge)`: the same service state machine, a `CameraEffectCompositor` rendering the frame's I420 planes on the CPU (box-blur or dim on a downscaled grid, the person blended back over it, fail-closed to the last-good effected frame or black out of a bounded `FrameBufferPool`), and a `PersonMaskProducer` over `MlKitPersonSegmenter` — ML Kit selfie segmentation in stream mode, its model inside the artifact — on the same 256x144 input and 15/s cap, the input carrying the frame's rotation so the model reads an upright scene and the mask it answers on that upright grid mapped back onto the input's own. `CameraThermalCadence` is the floor under that cap: `PowerManager`'s thermal status at light or above, held ten unbroken seconds, doubles the submission interval, and a status below it returns the target on the next submission — the listener is API 29, so hosts below it hold the fixed rate. `CameraEffectProcessors` pairs one of each per effect into a `CompositingEffectProcessor` whose `retire()` closes the producer and gives up the compositor's fallback claim; a frame still arriving takes the ordinary path and publishes a fresh whole-frame effect of itself. Direction names the owner across `CameraTrackBridging`: the host transfers one `CameraFrame` per representable frame and the core closes it exactly once before `processing` returns, `processing` answers a `PublishedFrame` over planes the core holds that the host closes before its capture callback returns — flutter_webrtc releases nothing a processor returns, so the Android host copies the publication into memory of its own and publishes the copy, and pixels are given up only by closing a frame — a frame the bridge cannot represent reaches no `CameraFrame` and no `processing` call. Consumer: transcript.chat's call background control | [lib/src/camera/x_camera_effects.dart](../lib/src/camera/x_camera_effects.dart) | [android/.../camera/effects/](../android/src/main/kotlin/io/swipelab/ux/camera/effects/) | [darwin/ux/Sources/ux_macos_core/CameraEffects/](../darwin/ux/Sources/ux_macos_core/CameraEffects/), [darwin/ux/Sources/ux/CameraEffects/](../darwin/ux/Sources/ux/CameraEffects/) |
| `XSecureStore` — string secrets by key over `ux/secure_store`: `read` / `write` / `delete`, where a missing key reads null, a write replaces, and deleting a key that holds nothing succeeds. Apple keeps one `kSecClassGenericPassword` Keychain item per key, service-scoped to the host bundle identifier and `kSecAttrSynchronizable` false so nothing reaches iCloud; iOS items are `kSecAttrAccessibleAfterFirstUnlock`, and macOS uses the file-based keychain because the data-protection keychain there answers `errSecMissingEntitlement` without a keychain-access-group entitlement. Android seals values with an AndroidKeyStore AES-256-GCM key — key material stays in the TEE, ciphertext (IV ++ sealed bytes, base64) sits in a private SharedPreferences file, key names in the clear. API 22 and below answers `unsupported` because Keystore AES requires API 23. Commands are serialized in Dart, so a read after a write observes it; neither side logs a key or a value. Consumer: transcript.chat's session token | [lib/src/secure_store/x_secure_store.dart](../lib/src/secure_store/x_secure_store.dart) | [android/.../SecureStorePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/SecureStorePlugin.kt) | [darwin/.../SecureStore/SecureStorePlugin.swift](../darwin/ux/Sources/ux/SecureStore/SecureStorePlugin.swift) |
| `XUrl` — URL / phone / email detection in text (FFI to `NSDataDetector` / `Patterns.WEB_URL`), an allowlisted `launch(url)` over `ux/url`, and `openAppSettings()`, the recovery link offered after a permission is denied. iOS opens `UIApplication.openSettingsURLString` and Android `ACTION_APPLICATION_DETAILS_SETTINGS` for the host package, both this app's own page; macOS has no per-app page, so it opens System Settings' Privacy & Security pane, where camera, microphone and screen-recording access is listed by app. On Windows, [windows/url_detect.cpp](../windows/url_detect.cpp) detects with AOSP's `Patterns.WEB_URL`, `EMAIL_ADDRESS` and `PHONE`, compiled once with the Windows SDK's ICU, which is Android's regex engine too, so Windows links what Android links, a bare domain included; [windows/url_plugin.cpp](../windows/url_plugin.cpp) launches with `ShellExecuteW`, and `openAppSettings()` answers false | [lib/src/url.dart](../lib/src/url.dart) | [android/.../UrlPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/UrlPlugin.kt) · [android/src/main/jni/url_detect.cpp](../android/src/main/jni/url_detect.cpp) | [darwin/.../iOS/UrlPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/UrlPlugin+iOS.swift) · [darwin/.../macOS/UrlPlugin+macOS.swift](../darwin/ux/Sources/ux/macOS/UrlPlugin+macOS.swift) · [darwin/.../ux_url_detect/url_detect.m](../darwin/ux/Sources/ux_url_detect/url_detect.m) |
| `XDrop` — files dragged onto a desktop app, over `ux/drop/events` (enter, update, exit and drop, at Flutter's global logical coordinates) and `ux/drop` (`setHasRegions`, and on macOS the folder zip's `zipDirectory`, `cancelZip` and `zipProgress`). Each `XDropRegion` hit-tests its own bounds; the native side claims a drag only while a region is active. A dropped `XDropFile` carries its path, name and `isDirectory`, and `isTemporaryCopy` for a copy the platform wrote into a directory of its own under `<temp>/ux_drops`, which the app owns. `startZip` zips a dropped folder into `<temp>/ux_drops/<uuid>/<folder>.zip` with the folder as the archive's root; a cancel answers null and a failure throws, and either removes that directory. macOS lays a dragging-destination overlay over the Flutter view for file URLs and file promises, receives each promise into a directory of its own and zips with ZIPFoundation. On Windows, [windows/drop_plugin.cpp](../windows/drop_plugin.cpp) registers an OLE `IDropTarget` on the Flutter view's window at the first listen, after `OleInitialize` on the platform thread, and revokes it on cancel and when the top-level window is destroyed. It maps the cursor into the view's client area divided by its DPI scale and reads `CF_HDROP`'s paths; a file offered only as `CFSTR_FILEDESCRIPTORW` with `CFSTR_FILECONTENTS`, in a block, a stream or a storage, it writes to `%TEMP%\ux_drops\<GUID>\<name>` ([windows/drop_data.cpp](../windows/drop_data.cpp)). `startZip` there runs in Dart ([lib/src/drop/folder_zip.dart](../lib/src/drop/folder_zip.dart)): an isolate deflates each file through dart:io's raw `ZLibEncoder`, computes its CRC-32, writes zip64 records past 4 GiB or 65,535 entries, and reports the fraction of bytes read. Consumer: banlu's chat and chat-list drop targets | [lib/src/drop/](../lib/src/drop/) | n/a | [darwin/.../macOS/DropPlugin.swift](../darwin/ux/Sources/ux/macOS/DropPlugin.swift) |
| `XClipboard` — images and copied files read from the system clipboard over `ux/clipboard`, which only reads: `readImage` answers an image's bytes, `readFiles` the copied files' paths and names, and `hasMedia` whether either is there, from the formats alone, so it reads no contents. macOS reads PNG, transcodes TIFF and mints a security-scoped bookmark for each file; iOS and Android read an image. On Windows, [windows/clipboard_plugin.cpp](../windows/clipboard_plugin.cpp) reads `CF_HDROP`'s paths, and the registered `PNG` format's bytes or else a `CF_DIBV5` or `CF_DIB` bitmap, off the platform thread. [windows/dib.cpp](../windows/dib.cpp) reads the bitmap's uncompressed rows of 1 to 32 bits a pixel, taking alpha from a V4 or V5 header's alpha mask, and WIC encodes them as PNG. `CF_DIBV5` comes first, since the `CF_DIB` Windows synthesizes from a 32-bit `CF_BITMAP` repeats its masks and loses its last 12 bytes, and the `CF_DIBV5` it synthesizes repeats the masks after its header. A read retries a clipboard another window holds open for 100 ms, then fails with `clipboard_busy`. Consumer: banlu's chat paste | [lib/src/clipboard.dart](../lib/src/clipboard.dart) | [android/.../ClipboardPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/ClipboardPlugin.kt) | [darwin/.../macOS/ClipboardPlugin+macOS.swift](../darwin/ux/Sources/ux/macOS/ClipboardPlugin+macOS.swift), [darwin/.../iOS/ClipboardPlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/ClipboardPlugin+iOS.swift) |
| `XFiles` — the platform's file services over `ux/file`: `pick`, `pickMultiple`, `open` with the default viewer, `saveCopy`, `showInFolder`, `share`, and scoped access to a picked file. On Windows, [windows/file_plugin.cpp](../windows/file_plugin.cpp) picks through an `IFileOpenDialog` owned by the Flutter window, with multiple selection for `pickMultiple`, which Windows alone serves; it filters by extension ([windows/file_types.cpp](../windows/file_types.cpp)): `image/*` and `video/*` allow the image and video files the app handles there, a concrete type its extensions, and none, `*/*` or a type whose extensions Windows does not know every file. A pick replies path, name, MIME type and size, with no bookmark. `open` hands the file to `ShellExecuteExW` with Windows's zone checks, so a file marked as downloaded meets SmartScreen and Office's Protected View, and a type with no associated application gets Windows's app chooser; a launch declined at SmartScreen answers true. `saveCopy` copies, over any file there, to the path an `IFileSaveDialog` holding the file's name returns, `showInFolder` opens Explorer on the file's folder with the file selected (`SHOpenFolderAndSelectItems`), and `share` opens the share window over the Flutter window (`IDataTransferManagerInterop`'s `GetForWindow` and `ShowShareUIForWindow`), whose data request receives the file as the `StorageFile` `GetFileFromPathAsync` opens off the platform thread, titled with `title` or else the file's name. The share window places itself, so `sourceRect` has no role there, and with no window `share` answers false. `videoThumbnail` and `videoThumbnails` decode frames through Media Foundation (see *Video frames and export (Windows)*) | [lib/src/file.dart](../lib/src/file.dart) | [android/.../FilePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/FilePlugin.kt) | [darwin/ux/Sources/ux/iOS/FilePlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/FilePlugin+iOS.swift) · [darwin/ux/Sources/ux/macOS/FilePlugin+macOS.swift](../darwin/ux/Sources/ux/macOS/FilePlugin+macOS.swift) |
| `XFiles.videoThumbnail` — single-frame poster extract, optionally BAKED: `transform3x3` + `outWidth`/`outHeight` (the exporter's upright-source-px→output-px affine contract) + `overlayPath` (strokes PNG composited before the affine) + `maxLongest` (final thumb cap) run entirely in the native software rasteriser (Android `Bitmap`/`Canvas`, Apple `CGContext`) and return the finished PNG. Callers must NOT re-rasterise the frame through Flutter's `Picture.toImage` — it silently returns blank/black frames in some device states (Huawei, after sleep/wake cycles; ~50% of calls). Consumer: banlu's send-time bubble thumb. | [lib/src/file.dart](../lib/src/file.dart) | [android/.../FilePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/FilePlugin.kt) | [darwin/ux/Sources/ux/iOS/FilePlugin+iOS.swift](../darwin/ux/Sources/ux/iOS/FilePlugin+iOS.swift) · [darwin/ux/Sources/ux/macOS/FilePlugin+macOS.swift](../darwin/ux/Sources/ux/macOS/FilePlugin+macOS.swift) |
| `XAppGroup` — Apple App Group container lookup (`containerPath(groupId)` → `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, null when the target isn't entitled). Consumer: banlu's data root, shared with its share extension. No Android analogue — the app and its share activity are one process | [lib/src/app_group.dart](../lib/src/app_group.dart) | n/a | [darwin/ux/Sources/ux_extension/AppGroupPlugin.swift](../darwin/ux/Sources/ux_extension/AppGroupPlugin.swift) |
| `XCrypto` — AES-256-CTR for upload encryption over `ux/crypto`: `aesCtrRange` reads a file's range and encrypts it natively, so only ciphertext crosses the channel, and `aesCtrBytes` encrypts the bytes it is given. A slice at `pos` encrypts as the same bytes of one stream from offset 0 do: the IV, a 128-bit big-endian counter, advances `pos >> 4` blocks and the first `pos & 15` keystream bytes are dropped. Android uses `javax.crypto`'s `AES/CTR/NoPadding` and Apple CommonCrypto's big-endian CTR. On Windows, off the platform thread, [windows/crypto_plugin.cpp](../windows/crypto_plugin.cpp) reads the range and [windows/aes_ctr.cpp](../windows/aes_ctr.cpp) encrypts the counter blocks with CNG's AES in ECB mode (`BCRYPT_AES_ECB_ALG_HANDLE`), which uses AES-NI where the CPU has it, and XORs that keystream over the data. `isSupported` is false off Android, iOS, macOS and Windows, where `aesCtrEncryptRange` reads the range and runs the pure-Dart `encryptChunk` on an isolate, as it does after a native error. Consumer: banlu's upload preparation (`FileService`, `ShareUploader`) | [lib/src/crypto.dart](../lib/src/crypto.dart) | [android/.../CryptoPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/CryptoPlugin.kt) | [darwin/ux/Sources/ux_extension/CryptoPlugin+macOS.swift](../darwin/ux/Sources/ux_extension/CryptoPlugin+macOS.swift), [darwin/ux/Sources/ux_extension/CryptoPlugin+iOS.swift](../darwin/ux/Sources/ux_extension/CryptoPlugin+iOS.swift) |
| `XVideoProbe` — one native round-trip describing a video file: upright display dimensions, duration, and a poster frame. No player and no texture registry, which is what lets an **app extension** host it — see the packaging note below. Apple backs it with `AVAsset` + `AVAssetImageGenerator`, Android with a single `MediaMetadataRetriever` (dimensions from the width/height metadata swapped by `METADATA_KEY_VIDEO_ROTATION`, poster from `getFrameAtTime`). A file with no video track reports null; a file whose frame won't decode still reports dimensions and duration. Consumer: banlu's share surface on both platforms, whose picker needs a video placeholder without spinning `XVideoPlayer` | [lib/src/video/x_video_probe.dart](../lib/src/video/x_video_probe.dart) | [android/.../VideoProbePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/VideoProbePlugin.kt) | [darwin/ux/Sources/ux_extension/VideoProbePlugin.swift](../darwin/ux/Sources/ux_extension/VideoProbePlugin.swift) |
| `XImageProbe` — upright dimensions and a downscaled PNG of an image file, in one native round-trip that **never materialises the full-resolution bitmap**. Flutter's own route (`instantiateImageCodec` over the bytes) costs 4 bytes per *source* pixel even to read the intrinsic size or make a 200px thumbnail — ~190 MB for a 48-megapixel photo, several times what an **app extension** is allowed. Apple reads the header with `CGImageSourceCopyPropertiesAtIndex` and renders through `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceCreateThumbnailWithTransform` applies the EXIF orientation, so reported dimensions and pixels agree); Android measures with `inJustDecodeBounds` and decodes subsampled via `inSampleSize`, then rotates by the `ExifInterface` orientation. Both allocate for the *output*. Lives in `ux_extension` for the same reason `XVideoProbe` does. On Windows, [windows/image_probe_plugin.cpp](../windows/image_probe_plugin.cpp) decodes off the platform thread through WIC ([windows/image_probe.cpp](../windows/image_probe.cpp)) with the codecs Windows has installed, HEIC and HEIF among them where the HEIF and HEVC extensions are: the orientation is `System.Photo.Orientation`, which is a JPEG's EXIF tag and 1 for HEIF, whose codec turns the image by its rotation item itself, and `thumbnail` scales through `IWICBitmapScaler` at the output size, turns the scaled pixels upright with `IWICBitmapFlipRotator` and encodes them with WIC's PNG encoder. `supported` is false off iOS, macOS, Android and Windows, where the caller keeps its own decode path. Consumer: banlu's outgoing-media preview (inline thumb + `thumbFile`), on every host | [lib/src/image/x_image_probe.dart](../lib/src/image/x_image_probe.dart) | [android/.../ImageProbePlugin.kt](../android/src/main/kotlin/io/swipelab/ux/ImageProbePlugin.kt) | [darwin/ux/Sources/ux_extension/ImageProbePlugin.swift](../darwin/ux/Sources/ux_extension/ImageProbePlugin.swift) |
| `XShortcuts` — per-conversation **Direct Share** targets in the OS share sheet. One Dart surface, `donate(targets, category)` / `clear()`, over two unrelated OS mechanisms. **Android**: dynamic shortcuts — the caller's ordered top-N replaces the set wholesale (`ShortcutManagerCompat.setDynamicShortcuts`, capped at `getMaxShortcutCountPerActivity`); each is long-lived, carries a `Person` + `LocusIdCompat` keyed by the caller's id, an adaptive-bitmap icon decoded from `iconPath`, and the caller's `category` — which the consuming app's `share-targets.xml` must also declare. The shortcut's own intent (a launcher tap) is the package launch intent; the share sheet instead routes to the `<share-target>` activity with `EXTRA_SHORTCUT_ID`. A shortcut the user pinned to their home screen is not the app's to delete, so `clear()` removes the dynamic set and *disables* whatever is pinned (`FLAG_MATCH_PINNED` → `disableShortcuts`) — otherwise a logout would leave the previous account's names and faces sitting on the launcher; `donate` re-enables the ids it publishes, so signing back in restores them. **iOS**: SiriKit donation — one `INSendMessageIntent` per target wrapped in an outgoing `INInteraction`, `conversationIdentifier` = the caller's id (what the consuming share extension reads back off `NSExtensionContext.intent`), `speakableGroupName` = the label, `INImage` from `iconPath`, and `INInteraction.identifier` = the caller's id so a re-donation replaces rather than accumulates. Donations are ranked by recency, so the list is donated tail-first; `clear()` is `INInteraction.delete(with:)` on the plugin's own group identifier, which is also what keeps `category` an Android-only argument. **macOS**: `supported` is false — AppKit's share menu has no conversation suggestions. Consumer: banlu's dialog list, donating its four most recent conversations | [lib/src/shortcuts.dart](../lib/src/shortcuts.dart) | [android/.../ShortcutsPlugin.kt](../android/src/main/kotlin/io/swipelab/ux/ShortcutsPlugin.kt) | [darwin/ux/Sources/ux/iOS/ShortcutsPlugin.swift](../darwin/ux/Sources/ux/iOS/ShortcutsPlugin.swift) (iOS only) |
| `XFile`, navi — see source | [lib/src/](../lib/src/) | mixed | mixed |

### Camera session ownership

`package:ux/media.dart` exposes `CameraSession`, the owner of a live camera
controller and its native allocation. `CameraPage()` creates and disposes its
own session. `CameraPage(session: session)` borrows one: the lending surface
(such as a picker) keeps ownership and disposes it when that surface closes.
Borrowing an initialized session preserves its controller and texture.

Preview surfaces listen to the session's current value. Audio replacement
publishes absence before releasing the old controller, then publishes its
replacement on the same lens; an audio initialization failure retries without
sound. Lens changes and `useController` operations serialize with replacement
and disposal. Closing the owner rejects new work immediately and releases any
in-flight initialization before its disposal future completes. Borrowed page
closure stops that page's recording and removes its listeners without closing
the session.

`CameraPage.filter` uses `XAssetKind`: image-only capture has no video switch
or long-press recording, video-only capture has no still mode, and null permits
both. Foreground microphone refresh and physical-orientation observation live
with the active page.

`MediaPickerPage` owns the gallery cell's session and lends it to `CameraPage`.
With granted or limited photo access, the camera occupies one column and two
rows, including in an empty album. Photo denial replaces the library with its
permission prompt; the camera cell and permission row are hidden. Session
reconciliation requires an open picker, confirmed camera access, and either an
existing loan to `CameraPage` or known
granted/limited photo access. A revoked loan is not replaced until it returns;
the loan ends before compose opens. Empty device discovery reserves no grid
space. Foreground transitions refresh both permissions; refresh results apply
only while current and while the picker remains open. Captures enter a
single-item `ComposePage` with the picker's purpose and submission handler;
the picker filter also restricts capture. Confirmation dismisses the picker
with the editor's results.

The picker lends `CameraPage` its `CameraCellSource`. The page's
`buildTransition` interpolates the live preview's bounds and corner radius,
fades the cell icon out and the camera chrome in, and reverses on cancel.
The cell retains its layout but yields painting, hit testing and semantics
only once the camera route is onstage; `onRemoved` returns them to the cell.
The native session remains owned by the picker throughout the flight.

Hosts render `Screen.buildTransition` with their route animation and call
`Screen.onRemoved` after the exit animation. `XRouter`/`ScreenStack` and a
Navigator route using `ScreenSlot` satisfy this contract without a Hero
controller or host-specific camera animation. The Navigator route retains
the picker while covered (`maintainState: true`).

Picker permission views use `MediaColors`, `MediaText.body` and the host's
`MediaStrings`: `cameraAccessRationale`, `photoAccessTitle`, `allowPhotoAccess`,
`openSettings`, `limitedPhotosRationale` and `manage`. The camera and
limited-library actions use `manage`; photo access uses `allowPhotoAccess`
before the first prompt and `openSettings` after denial or restriction.

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

### Windows plugin

`windows/` builds `ux_plugin.dll`, which Flutter registers as `XPluginCApi`
(pubspec `windows: pluginClass: XPluginCApi`).
[windows/CMakeLists.txt](../windows/CMakeLists.txt) compiles the C API
([include/ux/x_plugin_c_api.h](../windows/include/ux/x_plugin_c_api.h)) with the
handler sources [windows/sources.cmake](../windows/sources.cmake) lists.
`XPluginCApiRegisterWithRegistrar` calls `XPlugin::RegisterWithRegistrar`
([windows/x_plugin.cpp](../windows/x_plugin.cpp)), which hands the registrar one
handler per area, named after its darwin counterpart: `ClipboardPlugin`
(`ux/clipboard`), `CryptoPlugin` (`ux/crypto`), `DropPlugin` (`ux/drop` and
`ux/drop/events`), `FilePlugin` (`ux/file`), `ImageProbePlugin`
(`ux/image_probe`), `NotificationsPlugin`
(`ux/notifications` and `ux/notifications/events`), `UrlPlugin` (`ux/url`),
`VideoPlayerPlugin` (`ux/video` and `ux/video/events`), `VideoExporterPlugin`
(`ux/video/export` and `ux/video/export/events`) and `WindowPlugin`
(`ux/window` and `ux/window/events`). A handler serves its channel's contract
and answers not-implemented for a method it does not serve. Paths from Dart
are accepted with either separator.

- **FFI.** The host executable links `ux_plugin.dll`, and
  `lib/src/_ffi.dart` opens it by name, so `uxLib` resolves its exports,
  `ux_match_url` and `ux_free`. `XKeyboard` and `XSensors` find none of their
  symbols there and behave as on macOS.
- **Threads.** A handler replies and emits events on the platform thread, where
  its dialogs run. Work that blocks, such as decoding, encoding, capture, crypto
  or file I/O, runs off that thread and posts its result back:
  `PlatformThread::Background` ([windows/platform_thread.cpp](../windows/platform_thread.cpp))
  runs it on a thread of its own and hands its value back through a
  message-only window on the platform thread, and drops a value that arrives
  once the handler is gone. `ux_match_url` runs on the calling isolate's thread
  and is safe from several at once. A drag source serves its virtual files
  only while the drop target's `Drop` runs, unless it extracts asynchronously
  (`IDataObjectAsyncCapability`), so `DropPlugin` writes such a source's files
  there, and an asynchronous source's off the platform thread.
- **Lifetime.** The registrar destroys its handlers while the engine shuts
  down, after the engine has detached the messenger, so a handler's destructor
  neither unregisters a channel nor emits an event:
  `FlutterDesktopMessengerSetCallback` and `FlutterDesktopMessengerSend`
  dereference the engine the messenger no longer holds. The registrar's
  messenger, which holds the channels' callbacks, goes right after the
  handlers, and the client wrapper drops a reply a destructor completes.
- **Memory.** What a native call hands to Dart returns to the allocator that
  made it: `ux_free` frees the buffer `ux_match_url` returns.
- **SDK only.** C++17, built by MSVC, on the Windows SDK alone (Win32, COM and
  OLE, the shell, ICU, CNG, WIC, Media Foundation, Direct3D 11, and C++/WinRT
  for toasts and the share window). No third-party native code, test
  frameworks included.
- **Media Foundation.** `ux_plugin.dll` delay-loads `mfplat.dll` and
  `mfreadwrite.dll`, which an N edition of Windows lacks without the Media
  Feature Pack, so the DLL loads there. Every Media Foundation caller, the
  players' device and the frame and export work, starts it through
  `MediaFoundation` ([windows/media_foundation.cpp](../windows/media_foundation.cpp))
  before its first Media Foundation call. `MediaFoundation` loads those DLLs
  from the application's directory, the DLL directories it set or System32,
  never the working directory or `PATH`, and fails where they do not load; the
  caller then answers its error. Frame and export work, on a thread of its own,
  also joins COM's multithreaded apartment there (`MediaWork`).
- **Windows 10 1903.** The handlers compile against the SDK's declarations for
  build 18362 (`UX_PLUGIN_DEFINITIONS` in sources.cmake), and `ux_plugin.dll`
  imports `icu.dll`, which Windows has from 1903, so a host app needs 1903 or
  later.
- **Tests.** [windows/test/](../windows/test/) is a CMake project of its own,
  which no host app builds. It compiles sources.cmake's sources and its suites
  into `ux_test.exe` with the Flutter SDK's C++ client wrapper
  (`core_implementations.cc`, `standard_codec.cc` and `plugin_registrar.cc` from
  `<FLUTTER_ROOT>/bin/cache/artifacts/engine/windows-x64`), links
  `flutter_windows.dll.lib`, copies `flutter_windows.dll` beside the exe and
  registers each suite, `ux_test <suite>`, with `add_test`. It is configured
  with `-DFLUTTER_ROOT=<Flutter SDK>` for Visual Studio 17 2022 x64, built with
  `--config Debug` and run with `ctest -C Debug`, which banlu's `tool/be.sh
  ctest` does on its Windows machine. The `window` suite reads
  `ES_DISPLAY_REQUIRED` in the system execution state
  (`CallNtPowerInformation`), which Windows never sets for session 0, where
  services and SSH logons run with no display, so there it exits 77, CTest's
  skip; it runs in a user's session.

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

## Video pipeline (Windows)

[windows/video_player_plugin.cpp](../windows/video_player_plugin.cpp) serves
`ux/video` and `ux/video/events` with one `VideoPlayerInstance`
([windows/video_player_instance.cpp](../windows/video_player_instance.cpp)) per
handle, each an `IMFMediaEngine` in frame-server mode.

- **Device.** The players share one Direct3D 11 device
  ([windows/video_device.cpp](../windows/video_device.cpp)), created at the
  first `create` on the adapter Flutter renders with
  (`PluginRegistrarWindows::GetGraphicsAdapter`), with multithread protection
  on, and handed to every engine through one DXGI device manager. Media
  Foundation stays started while it lives, and where it does not start, as on
  a Windows N edition without the Media Feature Pack, `create` fails with
  `create_failed`.
- **Frames.** A pump thread per player polls `OnVideoStreamTick` every 8 ms and
  transfers each new frame with `TransferVideoFrame` into a BGRA texture
  ([windows/video_surface.cpp](../windows/video_surface.cpp)) that Flutter opens
  through its DXGI shared handle as a GPU-surface texture, then flushes and
  marks the texture's frame available. A frame of a new size goes into a new
  texture, shown once it is drawn; the one it replaces stays alive until
  Flutter next asks for the surface. Flutter sees no surface until the first
  frame.
- **Rotation.** The engine applies the track's rotation
  (`MF_MT_VIDEO_ROTATION`), so frames land upright and `initialize` answers
  the display size with `rotationQuarterTurns` 0, as on Android.
- **Sources.** `create` takes the `file://<path>` URI `XVideoPlayerController.file`
  builds, with either separator, and the engine opens the path as it is, spaces
  and non-ASCII characters included; any other URI answers `bad_args`.
- **Initialize.** `initialize` answers once the engine can play
  (`MF_MEDIA_ENGINE_EVENT_CANPLAY`), and fails with `decode_failed` and the
  engine's error when it cannot, as for a codec Windows has no decoder for.
- **Control.** `play` and `pause` act on the engine. `seekTo` seeks to the
  position and reports it at once. `setLooping` wraps playback at the end with no
  `completed`. `setPlaybackSpeed` sets the default rate as well as the current
  one, since `Play` starts at the default rate.
- **Events.** `stateChanged` carries `isPlaying` from the engine's play,
  pause, playing and ended events, `isBuffering` from its waiting, can-play
  and playing events, and the position with the buffered ranges every 100 ms once the player is
  ready. `sizeChanged` fires at ready and on a format change, `completed` when
  playback ends without looping, and `error` (`playback_failed`) for an engine
  error after ready.
- **Dispose.** `dispose` stops the pump, shuts the engine down and unregisters
  the texture, which Flutter releases once it is done with it.

## Video frames and export (Windows)

[windows/video_reader.cpp](../windows/video_reader.cpp) reads a file's first
video track through an `IMFSourceReader` with advanced video processing, which
decodes each frame to BGRA and turns it upright by the track's
`MF_MT_VIDEO_ROTATION`, and its first audio track, when asked, to 16-bit PCM at
44.1 or 48 kHz, in mono or stereo. An audio track Windows cannot decode is left
out, as Apple's exporter leaves out one it cannot read. The frames are drawn by
[windows/raster.cpp](../windows/raster.cpp), a software rasteriser over
premultiplied BGRA: a map that carries pixel centres onto pixel centres (a crop,
a quarter turn, a mirror) copies pixels, any other samples bilinearly, averaging
several samples per pixel where it shrinks the source, and the rows are drawn in
bands across up to 8 threads.

- **Frames.** `videoThumbnail` and `videoThumbnails`
  ([windows/video_thumbnail.cpp](../windows/video_thumbnail.cpp)) seek to the key
  frame at or before the requested time and decode on to the frame nearest it,
  which must lie within 500 ms, Apple's `AVAssetImageGenerator` tolerance. The
  frame comes back upright as a WIC PNG, scaled down to `maxWidth` when wider,
  or baked with `FilePluginBake`'s geometry: the frame and then the overlay
  PNG, in upright source pixels, are drawn through the affine into
  `outWidth`×`outHeight`, scaled so its longest edge fits `maxLongest`, with
  transparent pixels where the frame does not reach. An overlay that cannot be
  decoded is left out. A file Windows cannot decode, or a time with no frame
  within 500 ms, fails `videoThumbnail` with `decode_failed`;
  `videoThumbnails` answers null for such a frame, in timestamp order.
- **Export.** [windows/video_export.cpp](../windows/video_export.cpp) re-encodes
  every request on a thread of its own, since Windows has no passthrough remux:
  each frame from the trim start, or the frame shown at it, until the trim end
  is drawn upright through the request's affine (the upright frame without
  one) onto an opaque black canvas, the overlay drawn over it through the same
  affine, and written through an `IMFSinkWriter` as H.264 High profile from
  NV12, with a key frame each second and no B-frames, since the MP4 sink writes
  no edit list. The PCM in the trim range, cut to the sample, is written as
  AAC at 128 kbit/s, and `removeAudio` writes none. The encoder runs in low
  latency mode, which keeps it from queueing frames ahead, so an export's memory
  does not grow with its length. The bitrate is
  `videoBitrate`, or else the source's, at least 0.1 bit per pixel per frame,
  the density of Telegram's tiers; at 0.01 Windows's encoder renders flat
  colours visibly off. H.264 sides are even, so an odd side is rounded down.
- **Colour.** Windows's H.264 encoder states no colour space, and decoders,
  Media Foundation's among them, take BT.709 for frames over 576 rows and
  BT.601 for the rest, so `ToNv12` converts in that matrix.
- **Events.** `start` answers at once and the export reports on
  `ux/video/export/events`: `progress` from 0 to 1, then `done` with the path
  as Dart gave it, the canvas size and the trimmed duration, or `error` with
  `no_video_track`, `bad_trim`, `session_failed`, `export_failed` or
  `cancelled`. `cancel` stops the export at its next sample, and a failed or
  cancelled export deletes its partial file. A `start` under the id of a
  running session, as Dart's numbering after a hot restart gives, cancels that
  session, whose events are dropped.

## Notifications + window focus

`XNotifications` and `XWindow` share a two-channel shape: a `MethodChannel`
for commands and an `EventChannel` for native-pushed events. Each Dart
constructor only subscribes to its `EventChannel` on platforms that
register a native handler (`defaultTargetPlatform` gate) — otherwise
activating the stream throws `MissingPluginException`, which Flutter
reports straight to `FlutterError.onError`.

Handler coverage:

| | macOS | Android | Windows | iOS |
|---|---|---|---|---|
| `XWindow` (`ux/window/events`) | `NSApplication` active/resign | `ProcessLifecycleOwner` `ON_START`/`ON_STOP` | `WM_ACTIVATEAPP` on the top-level window | none — `focused` stays `true` |
| `XNotifications` (`ux/notifications` + `…/events`) | `UNUserNotificationCenter` | `NotificationManagerCompat` + `POST_NOTIFICATIONS` | C++/WinRT toasts | none |

On Android the two are coupled: `XWindow.focused` flipping to `false`
when the app backgrounds is what lets a consumer (Banlu's
`MessageNotifier`) post a local notification for a live socket message
while the process is alive but unfocused — the gap FCM intentionally
skips for socket-connected devices. The notification's tap `PendingIntent`
relaunches the app's launcher activity (resolved generically via
`getLaunchIntentForPackage`, no app class hard-coded) carrying the `data`
payload, which the plugin re-emits as a `tap` event; a tap that cold-starts
the process is buffered until Dart subscribes.

On Windows, `WindowPlugin` reports `WM_ACTIVATEAPP` on the Flutter view's
top-level window, a window procedure delegate it registers with the registrar
and unregisters when the registrar destroys it, and seeds each listen with
whether the foreground window is the platform thread's, so a minimized window
or another app in front starts out unfocused.

`NotificationsPlugin` shows toasts under the process's explicit
AppUserModelID (`GetCurrentProcessExplicitAppUserModelID`); every method of a
process without one fails with `no_app_user_model_id`, whose message names it.
The host sets it with `SetCurrentProcessExplicitAppUserModelID` before it
shows a window, and a Start-menu shortcut carrying the same ID registers the
app with Windows, which shows the toasts under the shortcut's name and icon.

- `show` builds a ToastGeneric toast ([windows/toast.cpp](../windows/toast.cpp))
  with the title and the body as its two lines and `data` as a JSON object of
  strings in its `launch` argument. Its `Tag` is the id and its `Group` the
  thread id, so a toast with the same id and thread replaces the earlier one.
- `cancelByThread` removes the thread's group from the app's toast history and
  `cancelAll` clears that history.
- `requestPermission` answers whether the notifier's `Setting` is `Enabled`,
  since Windows shows a desktop app no prompt, and emits `authorization`.

Clicks reach the app through COM. The host names its toast activator, the
`ToastActivatorCLSID` its shortcut carries, with
`XPluginCApiSetToastActivator` before it registers its plugins, and registers
that CLSID's `LocalServer32` as its executable. While it lives, the plugin
registers a class object for the CLSID (`CoRegisterClassObject`, revoked when
the registrar destroys it), whose `INotificationActivationCallback::Activate`
hands the click's launch argument to the platform thread. There the plugin
restores the top-level window when it is minimized, brings it to the front and
emits `tap` with the launch argument's data. A click while the app is not
running has COM start the `LocalServer32` executable with `-Embedding`, so the
app starts, and its `tap` reaches no Dart listener, as on macOS.
