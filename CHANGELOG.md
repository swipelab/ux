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
