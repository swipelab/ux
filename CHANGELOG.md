### 0.10.0
- **`Sheet` arbitrates drags against the attached scroll view by that
  view's own axis.** The list scrolls while it has content left in the
  drag direction — from every snap, not only when expanded — and the same
  gesture hands off to sheet movement once the list reaches that edge. A
  reversed list (a chat transcript) therefore scrolls toward older content
  on a down-drag; a gesture that starts on sheet chrome moves the sheet
  whatever the list is showing; and a sheet displaced mid-gesture keeps the
  gesture until it is back at its snap.
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
