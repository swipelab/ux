### 0.18.0
- **A web link keeps the slash that ends it.** On Android and Windows, a web
  match that text follows keeps its path's trailing `/`, the other path
  punctuation a URL may end in, such as `?`, `=`, `#`, `-` and `*`, and a
  trailing `)` it opens, as on macOS. A link typed with a trailing `/` is
  complete when a space is typed after it.
- **A web link ends before CJK punctuation.** On every platform, `XUrl.match`
  ends a web match before ideographic, fullwidth and halfwidth punctuation
  such as `。`, `，`, `、`, `；`, `：`, `！` and `？`, and starts a bare domain
  match after one. A link ending a Chinese sentence opens without the mark and
  the text after it, and a link typed before one of these marks is complete
  when the mark is typed.
- **A web link leaves out the period after it.** On Android and Windows, and
  for the bare domains with a path that macOS matches beside `NSDataDetector`,
  `XUrl.match` ends a web match before a trailing `.`, `,`, `;` or `!` and
  before a trailing `)` the link does not open. A link that ends a sentence
  opens without the period, and a link typed before one of these marks is
  complete when the mark is typed.
- **Windows probes images.** `XImageProbe.size` and `XImageProbe.thumbnail`
  answer on Windows through WIC, upright with the image's orientation applied,
  for every format an installed codec decodes, HEIC and HEIF included where
  Windows has the HEIF and HEVC extensions, and null for a file none decodes.
  `XImageProbe.supported` is true on Windows, and the file dialog's `image/*`
  filter there allows heic and heif.
- **Windows extracts video frames and exports videos.** `XFiles.videoThumbnail`
  and `videoThumbnails` decode through Media Foundation the frame nearest each
  time, within 500 ms, upright, scaled to `maxWidth` or baked with the transform
  and overlay as on Apple platforms. `XVideoExporter` re-encodes every request
  on Windows to an H.264/AAC MP4, trimmed from the trim start exactly, without
  audio when muted, and with the transform and overlay drawn upright, at
  `videoBitrate` or else the source's bitrate, at least 0.1 bit per pixel per
  frame. Progress runs from 0 to 1, `done` answers the path, the size and the
  duration, and `cancel` deletes the partial file and fails with `cancelled`.
  Where Windows has no Media Foundation, each fails with its error.
- **Windows plays videos.** `XVideoPlayerController.file` plays on Windows
  through Media Foundation's Media Engine into a Flutter texture. `initialize`
  answers the display size and the duration, with `rotationQuarterTurns` 0
  since the frames arrive upright, and fails with `decode_failed` for a file
  Windows cannot decode. Play, pause, seek, looping, volume and speed act as on
  the other platforms, and the player reports its state, size, completion and
  errors. On Windows a network URI fails `initialize` with `bad_args`, and
  where Media Foundation is missing, as on a Windows N edition without the
  Media Feature Pack, `initialize` fails with `create_failed` while the rest of
  the plugin works.
- **A video player logs its metadata.** `XVideoPlayerController.initialize`
  logs `initialized` at info level, tagged `video`, with the player's handle,
  size, duration and quarter turns.
- **Windows picks, opens, saves and reveals files.** `XFiles.pick` and the new
  `XFiles.pickMultiple`, which returns the picked files in order or an empty
  list when the user cancels and which Windows alone serves, open the Windows
  file dialog, filtered by extension. `XFiles.open` launches the file's
  associated application through Windows's checks for a downloaded file,
  `saveCopy` copies through the save dialog, and `showInFolder` selects the file
  in Explorer. `supportsSaveCopy` and `supportsShowInFolder` are true on
  Windows.
- **ux has a Windows plugin.** The pubspec declares `windows: pluginClass:
  XPluginCApi`, built as `ux_plugin.dll` on the Windows SDK alone, for Windows
  10 1903 or later. `XUrl.match` detects web, email and phone links there with
  AOSP's `Patterns.WEB_URL`, `EMAIL_ADDRESS` and `PHONE`, as Android does, so a
  bare domain is a link where macOS's detector leaves it plain. `XUrl.launch`
  opens a URL with the handler Windows has for its scheme, and
  `openAppSettings` answers false. `windows/test` holds the plugin's native
  tests.
- **Avatar editors close on accept.** `ComposeResult.imageBytes` is a
  `Future<Uint8List>` encoded after `ComposePage` pops, so the caller shows
  progress where the image lands; it fails with a `FormatException` when the
  image cannot be decoded. `MediaPickerPage.maxImageExtent` and
  `ComposePage.maxImageExtent` bound the longest edge of those bytes.
  Breaking: `ComposeResult.imageBytes` is a future, and
  `ComposeEntry.resolveImageBytes` is replaced by `ComposeEntry.captureImage`.
- **Avatar editors confirm with the app's primary button.** `ComposePage`
  lays `MediaHost.confirmButton` full width under the editing tools wherever
  no caption field sends the edit. Breaking: hosts implement
  `MediaHost.confirmButton`, and `MediaCommandsBar.onConfirm` is removed.
- **Network video players open without blocking the UI on iOS and macOS.**
  The player loads the video's rotation once the header has downloaded, and
  `initialize` reports it with the size and duration.
- **A video player's size is its display size.** `XVideoPlayerValue.size`,
  `XVideoPlayerMetadata.size` and `XVideoPlayerSizeChanged.size` are the
  dimensions after the track's rotation on every platform, so a portrait
  recording reports portrait. `rotationQuarterTurns` is the correction
  `XVideoPlayerView` applies to the texture: the track's rotation on iOS and
  macOS, 0 on Android, where the texture arrives upright. Size a box from
  `size` alone, without swapping it on odd turns.
- **A disposed video player stays disposed.** A native player created after
  `XVideoPlayerController.dispose` is disposed at once, and no listener hears
  from the controller after `dispose`. A call the native side answers after
  `dispose`, `initialize` included, changes nothing and fails with
  `XVideoPlayerException('disposed')`. `dispose` completes when the native
  player fails to tear down. Disposing a player while its `initialize` waits
  for the video fails that `initialize` with
  `XVideoPlayerException('disposed')`.
- **A disposed compose entry stays disposed.** A `ComposeEntry` disposed
  while its video, crop poster, draw overlay or composite is still loading
  neither notifies nor changes its state, and releases a poster that arrives
  late. `ComposeEntry.captureImage` returns null once the entry is disposed.
  `ComposeEntry.disposeVideo` drops the player and notifies before the native
  player finishes tearing down.
- **A compose entry captures the edits its preview is still rendering.**
  `ComposeEntry.composedImage` and `ComposeEntry.captureImage` wait for the
  render of the current edits, and a render an edit overtakes is discarded.
- **A video compose entry decodes its crop poster once.** Tools opened
  together share the one poster.
- **A `ScreenShell` keeps screens it hosts but does not show.**
  `ScreenShell.hosted` lists every screen a shell hosts and `pages` the ones
  it shows. A hosted screen left out of `pages` stays mounted offstage with
  its State, unpainted, out of hit testing and focus, its tickers muted. It
  hides, shows again and leaves at once, without a transition, and focus
  inside it goes back to the shell. `ScreenShell.pagesChanged` tells the
  router that the shown screens changed outside a push or a pop, and the
  router re-renders and recomputes the active screen, the system-back state
  and the orientations. `XRouter.hosted` lists every screen the router holds,
  and `XRouter.pages` the shown ones. `popAll` pops hidden screens too, and a
  push equal to a screen `home` hosts asks it to `ScreenShell.show` that
  screen.
- **A `ScreenShell` places its hosted screens and hosts screens beside it.**
  `ScreenShell.place` wraps a hosted screen's slot to lay out where it draws,
  under the window's `MediaQuery`. A screen `ScreenShell.isBeside` marks
  moves no focus as it comes and goes, except that focus inside one that
  leaves goes to the shell. Tab and Shift+Tab cross between the shell and the
  screen, and the screen takes no edge-swipe or predictive-back drag, so
  system back reaches the shell's `handleBack`. A screen keeps its State when
  its placement, its beside mark or the shape of its transition changes.
  `ScreenStack` takes `hidden`, `beside` and `place`.
- **A back gesture moves a screen with the finger.** The iOS edge swipe
  moves a screen by the finger's travel since the touch went down.
  `ScreenSlot.curved(context, animation, curve)` is `animation` on `curve`:
  while a back gesture drives the slot it is the gesture's own progress, and
  once the gesture lets go, or the screen leaves, it runs the curve from where
  the screen shows to where the transition settles. `ScreenTransitions` take
  their curves through it. The spring back returns over 150 ms on the
  transition's curve.
- **A media caption is what the host's caption field holds.**
  `ComposeResult.caption` is what `MediaHost.caption` reads from the item's
  caption controller when the page submits, in the host's own type: the host
  trims it and keeps what its field holds beside the text, such as formats.
  Breaking: hosts implement `MediaHost.caption`, and `ComposeResult.caption`
  is an `Object?`.

### 0.17.0
- **`media.dart` holds one snapshot flight.** `GalleryTransition` uses
  `MediaFlightSurface` for current media pixels, `MediaFlightChrome` for
  stationary controls, and `HiddenMedia` for source visibility.
  `kMediaFlightDuration` is the shared 300 ms camera, compose and gallery
  route duration. `GallerySource.borderRadius` supplies the source shape.
  Picker snapshots retain the full bitmap so image quality upgrades preserve
  framing. Without an opening snapshot, media fades at its destination.
  Breaking: `GalleryOpenTransition`, `GalleryCloseTransition`,
  `kGalleryOpenChrome`, `kGalleryOpenPosition`, `kGalleryOpenBounds`,
  `kGalleryOpenPushed`, `kGalleryOpenCopyAlpha`, `kGalleryCloseSpatial` and
  `kGalleryCloseChrome` are removed; hosts use `GalleryTransition` and
  implement `GallerySource.borderRadius`.

### 0.16.0
- **`media.dart` holds the live picker camera cell.** `MediaPickerPage`
  shows a two-row preview with granted or limited photo access, lends its
  `CameraSession` to `CameraPage`, and sends captures through `ComposePage`
  with the picker's filter, purpose and submission handler. `CameraCell`
  and `CameraCellSource` carry the animated preview between grid and camera;
  cancellation returns to the picker with its gallery selection intact.
  `CameraPage` supports borrowed sessions and image-only or video-only capture.
  Permission views use host colours, text and strings, and foreground return
  refreshes camera and photo access. `XCameraController` exposes
  `cameraPermissionGranted()` without prompting or opening a session, and
  `requestCameraPermission()` with a Settings fallback. New development
  dependency: `cupertino_icons` for test fonts. Breaking: hosts implement
  `MediaStrings.cameraAccessRationale`, `photoAccessTitle`, `allowPhotoAccess`,
  `openSettings`, `limitedPhotosRationale` and `manage`, render
  `Screen.buildTransition` and call `Screen.onRemoved` after exit (through
  `XRouter`/`ScreenStack` or a Navigator route using `ScreenSlot` with
  `maintainState: true`), and declare Android `android.permission.CAMERA`,
  Apple `NSCameraUsageDescription` in `Info.plist`, and macOS
  `com.apple.security.device.camera` in debug and release entitlements; custom `XCameraBackend` implementations
  supply `cameraPermissionGranted()` and `requestCameraPermission()`.

### 0.15.0
- **`media.dart` holds the media picker and the camera.** `MediaPickerPage`
  with its albums screen, grid cell, selected strip, permission views,
  `SelectionContext` and `ThumbnailCache`; `CameraPage` with the shutter, flash
  and photo/video controls, `CameraThumb` and `normalizeCameraCapture`.
  `MediaHost` gains `lifecycle` and `isWideScreen`. New dependencies:
  `collection`, and `swipelab_webp` from the sibling checkout
  `../swipelab_webp`, so the package is `publish_to: none`. Breaking: a
  `MediaHost` implements the two new members.

### 0.14.0
- **`media.dart` holds the compose page.** `ComposePage` and `ComposeEntry`
  with the crop and draw tool screens and the video trim scrubber; the gallery
  open and close transition with `GallerySource`; `DismissCarrier`,
  `HiddenMediaController`, the video painters, `XMedia` and the gallery timing
  constants. `MediaHost` gains `push`, `captionController`, `captionField` and
  `keyboardInsets`. New dependencies: `path`, `path_provider`. Breaking: a
  `MediaHost` implements the four new members.

### 0.13.0
- **`media.dart` holds the image editors.** `Editor` with its crop, draw and
  text tools: `CropImageLayer`, `DrawImageLayer`, `EntityLayer`, their
  gestures, controls and painters, `Animator`, `CameraFit` and the text
  entity model. `MediaHost` gains `insets` and the text `family`. New
  dependencies: `flutter_svg`, `vector_math`. The brush illustrations ship as
  package assets.

### 0.12.0
- **`media.dart`.** `MediaHost`, through which the media flow reads the
  hosting app's colours, type, icons and strings, with `Touch`,
  `CountOdometer`, `MediaCommandsBar`, `MicPermissionBanner`, the EXIF
  orientation reader and `VideoEditValues`.

### 0.11.0
- **`ux.dart` is pure.** It exports core, reactive, navi, anim and the
  geometry helpers, and compiles for the web. Each native component is
  imported from its own library: `audio.dart`, `camera.dart`,
  `screen_sources.dart`, `video.dart`, `image.dart`, `clipboard.dart`,
  `crypto.dart`, `notifications.dart`, `secure_store.dart`, `window.dart`,
  `drop.dart`, `file.dart`, `gallery.dart`, `keyboard.dart`, `scanner.dart`,
  `shortcuts.dart`, `url.dart`, `sensor.dart`, `crash.dart`, `log.dart`,
  `app_group.dart`. Breaking: add the library a symbol lives in.

### 0.10.0
- **Apple host executables export dart:ffi process symbols.** Keyboard,
  sensor, and URL-detect entry points are looked up in the process; the
  host app's release strip keeps globals (`STRIP_STYLE = non-global`).
- **`XAudioCapture` picks its source.** `sources()` lists the hardware inputs
  the OS names plus, on macOS and Android 10+, one `playback` source for what
  the device plays; `start({sourceId})` opens it. Omitting `sourceId` is the
  default microphone under the platform voice processing. A
  microphone id opens that input, also under voice processing; the playback id
  taps the output raw — macOS through an audio-only `SCStream` under the
  screen-recording grant, Android through a media-projection consent the
  plugin asks for itself. iOS lists no playback source. Frames stay mono
  16 kHz Int16 of 320 samples, one source at a time: changing source is `stop`
  then `start`, and an id naming nothing throws `unknown_source`.
- **`XAudioCapture.start({voiceProcessing})`.** The default microphone and a
  microphone id capture under the platform voice processing when
  `voiceProcessing` is true (the default): Apple enables the voice-processing
  I/O unit, Android records `VOICE_COMMUNICATION` with echo cancellation.
  False leaves the microphone raw — no echo cancellation and no output
  ducking. A playback tap stays raw.
- **`Sheet` arbitrates drags against the attached scroll view by that
  view's own axis.** A down-drag scrolls a list with content left in that
  direction from every snap, while an up-drag from a non-expanded snap
  expands the sheet first. The same gesture hands off at an edge. A reversed
  list (a chat transcript) scrolls toward older content on a down-drag;
  sheet-chrome drags move the sheet, decided by the pointer that opens the
  gesture; and a displaced sheet keeps the gesture until it returns to its
  snap.
- **Darwin sources unified and moved to Swift Package Manager.** iOS and macOS
  now build from one package at `darwin/ux/` (`sharedDarwinSource: true`);
  `ios/` and `macos/` are gone, as are both podspecs — the plugin no longer
  supports CocoaPods. Consumers on a recent Flutter get SPM automatically and
  can `pod deintegrate`. `ZIPFoundation` is now an SPM dependency (macOS only).
  Removes the podspec copy-mirror of `darwin/{Camera,Video,File}` into
  `Classes/*-shared`, which existed only because CocoaPods cannot glob through
  symlinks — SPM reads the shared sources directly, so they can no longer go
  stale between builds.
- `XGallery.saveToLibrary(path, kind, mimeType?)`: add a file on disk to the
  system photo library. iOS requests add-only authorization (`.addOnly`
  "Allow Adding Photos?" prompt) then `performChanges`; Android inserts via
  `MediaStore` under `Pictures/<app>` / `Movies/<app>` (`IS_PENDING` flow on
  API 29+, `WRITE_EXTERNAL_STORAGE` + public-dir copy + media-scan below).
  Returns `XGallerySaveStatus {saved, denied}`; hard failures throw.
  `XGallery.supportsSaveToLibrary` gates UI (iOS / Android).
- `XFiles.saveCopy(path, mimeType?)`: save a user-visible copy of any file.
  iOS presents the system export picker ("Save to Files"); Android inserts
  into the Downloads collection (API 29+) or copies into public Downloads
  behind a `WRITE_EXTERNAL_STORAGE` grant (<29); macOS presents an
  `NSSavePanel` and copies to the chosen destination. Returns
  `XFileSaveStatus {saved, cancelled, denied}`. Gated by
  `XFiles.supportsSaveCopy` (iOS / Android / macOS).
- `XFiles.supportsShare`: capability gate for the existing `share` sheet
  (iOS / Android / macOS).
- `FakeXGalleryBackend`: implements `saveToLibrary`, records calls in
  `savedToLibrary`, outcome overridable via `onSaveToLibrary`.
- `XScreenSources`: the displays and windows a screen-share picker offers, as
  one snapshot over `ux/screen_sources` (macOS 14+). `list(allowedDisplayIds:,
  allowedWindowIds:, thumbnailWidth:, thumbnailHeight:)` intersects the
  caller's allow-sets with what is on screen and returns each survivor as an
  id, kind, title, owning application, source pixel dimensions and an
  aspect-fit PNG thumbnail; a source whose thumbnail fails to render comes back
  with a null `thumbnailPng`, and `thumbnail_failed` is thrown only when no
  requested source rendered. `list` never prompts — `hasPermission` /
  `requestPermission` are explicit. `XScreenSourcesBackend.instance` is
  settable and `FakeXScreenSourcesBackend` ships in `package:ux/testing.dart`.
- `XCameraEffects`: none / blur / dim behind the person on the outgoing camera
  track, over `ux/camera_effects` (+`/events`) (macOS 12+). `setEffect(trackId,
  effect)` hands the local video track to the native processor and `clear()`
  gives it back its own frames; `status` (`idle`/`applying`/`active`/`failed`)
  is the processor's account of the frames. Compositing is Core Image with a
  Vision person mask, and a failure falls back to the last good effected frame
  or black, never the raw input. The host app supplies its camera stack by
  conforming to `CameraEffectsBridge` and calling `CameraEffects.install(_:)`;
  without it commands answer `integration_unavailable`.
  `XCameraEffectsBackend.instance` is settable and `FakeXCameraEffectsBackend`
  ships in `package:ux/testing.dart`.

### 0.9.0
- `XScanner`: new platform-view widget for QR-code (and forward-compat
  barcode) scanning. iOS uses `AVCaptureMetadataOutput` (no extra pod);
  Android uses CameraX preview + ZXing decoder
  (`com.google.zxing:core:3.5.3`, ~470 KB jar, no Play Services dep).
  `XScannerPermission.requestCamera()` requests OS permission first;
  decoded payloads stream through `EventChannel('ux/scanner/events')`.

### 0.8.0
- `Log`: pretty, production-ready logger. Static entry (`Log.d/i/w/e/f/t`),
  scoped loggers via `Log.tag('KB')`, lazy messages (`Log.d(() => expensive)`),
  structured `fields`, ANSI-colored `ConsoleSink`, `DeveloperSink` for DevTools,
  `MemorySink` ring buffer (tests + breadcrumbs), `NoopSink`. Sinks fan out via
  `+` with per-sink `minLevel`; throwing sinks can't take down the pipeline.
- `Log.configure`: one-call setup that also wires `FlutterError.onError`,
  `PlatformDispatcher.onError`, and isolate errors through `Log.e`. Pair of
  log-then-rethrow is deduped via an `Expando` mark so crash handlers don't
  double-report. Override the `captureCrashes` hook to customise or pass
  `() {}` to opt out.
- `XKeyboard`: adaptive-learning debug output now uses `Log.tag('KB').d`
  instead of `print`, lazy-built so the formatted line is only constructed
  when debug level is enabled.

### 0.7.0
- `AutoMap<K, V>`: insertion-ordered collection with O(1) lookup by key
  **and** by index. Backed by a `List<V>` + `Map<K, int>` kept in sync by
  four mutation methods (`add`, `addAll`, `remove`, `clear`); both fields
  are private so callers cannot break the invariant. Extends `Iterable<V>`
  for `where` / `map` / `firstWhere` / etc. `remove` is O(n) to preserve
  order; every other op is O(1).

### 0.6.0
- `XFile`: new module for handing files to the OS
  - `XFile.share(path, {title, mimeType, sourceRect})` — iOS `UIActivityViewController`,
    macOS `NSSharingServicePicker`, Android `Intent.ACTION_SEND` via FileProvider.
    `sourceRect` anchors the popover on iPad / macOS.
  - `XFile.open(path, {mimeType})` — in-app preview where possible:
    iOS `QLPreviewController`, macOS `QLPreviewPanel` (preview on top of the app,
    no foreground loss), Android `Intent.ACTION_VIEW` with MIME inference from
    `MimeTypeMap` + a fallback set of text/code extensions so unknown types
    still resolve to `text/plain` instead of `application/octet-stream`.
- **macOS**: new platform. Plugin registry + `FilePlugin`; keyboard and sensor
  plugins remain iOS-only.
- Android: ships a FileProvider under `${applicationId}.ux.fileprovider`
  scoped to `ux_share/` in the app cache — host apps don't need manifest
  plumbing.
- iOS: `XWindow` helper (`keyWindow` / `topViewController`) in
  `NativePlugin.swift`, shared between keyboard and file plugins.

### 0.5.0
- `XSensor.orientation`: accelerometer-driven physical device rotation,
  independent of the OS auto-rotate setting or UI orientation lock
- `AppInfo`: version + buildNumber surface
- `XKeyboard`: focus tracking integration

### 0.4.0
- `package:ux/testing.dart`: new entry point for test-only utilities
- `matchesTextGolden(path, {update})`: `matchesGoldenFile`-style matcher for
  plain-text snapshots (RPC responses, log output, formatted data). Writes on
  first run or when `update: true`; compares byte-for-byte otherwise. Runtime
  stays flutter_test-free — depends only on `package:matcher`. For
  flutter_test users, pass `update: autoUpdateGoldenFiles` so
  `flutter test --update-goldens` regenerates text goldens too.

### 0.3.0
- `XKeyboard`: fix interactive dismiss race conditions — keyboard height no longer
  gets stuck when rapidly dismissing and re-focusing
- `XKeyboard`: handle zero-duration keyboard notifications (instant snap)
- `XKeyboard`: gate adaptive learning debug output behind `kDebugMode`
- Example: rewrite as chat UI demonstrating `ListenableBuilder`, scroll freeze,
  and interactive dismiss
- Example: modernize Android project (v2 embedding, AGP 8.7, Gradle 8.11)

### 0.2.0
- `XKeyboard`: sampled native animation curves (iOS & Android) with adaptive learning
- `XKeyboard`: interactive dismiss via pan gesture
- Android: keyboard height tracking via JNI/FFI bridge

### 0.1.1
- Bezier utilities

### 0.0.3
- Action Plan

### 0.0.2
- BendBox
