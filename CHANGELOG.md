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
