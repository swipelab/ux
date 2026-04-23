### 0.7.0
- `AutoMap<K, V>`: insertion-ordered collection with O(1) lookup by key
  **and** by index. Backed by a `List<V>` + `Map<K, int>` kept in sync by
  four mutation methods (`add`, `addAll`, `remove`, `clear`); both fields
  are private so callers cannot break the invariant. Extends `Iterable<V>`
  for `where` / `map` / `firstWhere` / etc. `remove` is O(n) to preserve
  order; every other op is O(1).

### 0.6.0
- `UxFile`: new module for handing files to the OS
  - `UxFile.share(path, {title, mimeType, sourceRect})` — iOS `UIActivityViewController`,
    macOS `NSSharingServicePicker`, Android `Intent.ACTION_SEND` via FileProvider.
    `sourceRect` anchors the popover on iPad / macOS.
  - `UxFile.open(path, {mimeType})` — in-app preview where possible:
    iOS `QLPreviewController`, macOS `QLPreviewPanel` (preview on top of the app,
    no foreground loss), Android `Intent.ACTION_VIEW` with MIME inference from
    `MimeTypeMap` + a fallback set of text/code extensions so unknown types
    still resolve to `text/plain` instead of `application/octet-stream`.
- **macOS**: new platform. Plugin registry + `FilePlugin`; keyboard and sensor
  plugins remain iOS-only.
- Android: ships a FileProvider under `${applicationId}.ux.fileprovider`
  scoped to `ux_share/` in the app cache — host apps don't need manifest
  plumbing.
- iOS: `UxWindow` helper (`keyWindow` / `topViewController`) in
  `NativePlugin.swift`, shared between keyboard and file plugins.

### 0.5.0
- `UxSensor.orientation`: accelerometer-driven physical device rotation,
  independent of the OS auto-rotate setting or UI orientation lock
- `AppInfo`: version + buildNumber surface
- `UxKeyboard`: focus tracking integration

### 0.4.0
- `package:ux/testing.dart`: new entry point for test-only utilities
- `matchesTextGolden(path, {update})`: `matchesGoldenFile`-style matcher for
  plain-text snapshots (RPC responses, log output, formatted data). Writes on
  first run or when `update: true`; compares byte-for-byte otherwise. Runtime
  stays flutter_test-free — depends only on `package:matcher`. For
  flutter_test users, pass `update: autoUpdateGoldenFiles` so
  `flutter test --update-goldens` regenerates text goldens too.

### 0.3.0
- `UxKeyboard`: fix interactive dismiss race conditions — keyboard height no longer
  gets stuck when rapidly dismissing and re-focusing
- `UxKeyboard`: handle zero-duration keyboard notifications (instant snap)
- `UxKeyboard`: gate adaptive learning debug output behind `kDebugMode`
- Example: rewrite as chat UI demonstrating `ListenableBuilder`, scroll freeze,
  and interactive dismiss
- Example: modernize Android project (v2 embedding, AGP 8.7, Gradle 8.11)

### 0.2.0
- `UxKeyboard`: sampled native animation curves (iOS & Android) with adaptive learning
- `UxKeyboard`: interactive dismiss via pan gesture
- Android: keyboard height tracking via JNI/FFI bridge

### 0.1.1
- Bezier utilities

### 0.0.3
- Action Plan

### 0.0.2
- BendBox
