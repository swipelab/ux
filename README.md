# ux

A Flutter toolkit for building fluid, native-feeling UIs.

## Libraries

`package:ux/ux.dart` is plain Dart and Flutter — core, reactive, navi, anim,
bezier — and runs everywhere, the web included. Each native component is a
library of its own:

| Library | Holds |
| --- | --- |
| `app_group.dart` | storage shared with app extensions |
| `audio.dart` | `XAudioCapture`, `XAudioSink` |
| `camera.dart` | `XCamera`, preview, effects |
| `clipboard.dart` | rich clipboard |
| `crash.dart` | native crash reports |
| `crypto.dart` | AES-CTR |
| `drop.dart` | `XDrop` |
| `file.dart`, `gallery.dart` | picked files, photo library |
| `image.dart`, `video.dart` | probes, `XVideoPlayer`, `XVideoExporter` |
| `keyboard.dart` | `XKeyboard` |
| `log.dart` | console and HTTP sinks |
| `media.dart` | `MediaHost`, the media picker with its live camera cell (`MediaPickerPage`, `CameraCell`, `CameraCellSource`), the camera and shared session (`CameraPage`, `CameraSession`, `normalizeCameraCapture`), the compose page (`ComposePage`, `ComposeEntry`, `XMedia`), the gallery transition (`GalleryTransition`, `GallerySource`, `DismissCarrier`), the image editors (`Editor`, crop, draw, text), `Touch`, `CountOdometer`, `MediaCommandsBar`, `MicPermissionBanner`, EXIF orientation, `VideoEditValues` |
| `notifications.dart` | `XNotifications` |
| `scanner.dart` | `XScanner` |
| `screen_sources.dart` | `XScreenSources` |
| `secure_store.dart` | `XSecureStore` |
| `sensor.dart`, `shortcuts.dart`, `url.dart`, `window.dart` | the rest |

## XKeyboard

Frame-accurate keyboard height tracking for iOS and Android, with interactive dismiss.

Flutter's built-in `MediaQuery.viewInsets.bottom` lags behind the actual keyboard position
and doesn't support interactive dismiss. `XKeyboard` reads the keyboard height directly
from the native layer via FFI — zero channel latency, every frame.

### Features

- **Real-time height** — reads the keyboard's actual position each frame via FFI (iOS) / JNI (Android)
- **Native animation curves** — sampled from `CADisplayLink` (iOS) and `WindowInsetsAnimation` (Android),
  with adaptive learning that refines the curve from observations
- **Interactive dismiss** — drag the keyboard down like iMessage/Telegram, with snap-back or dismiss. On iOS a downward drag from the chat (stream or composer) tracks; velocity at lift-off commits dismiss or snap-back. A downward swipe on the IME itself also tracks.
- **Scroll freeze** — `isTracking` flag lets you freeze scrolling during interactive dismiss

### Quick start

```dart
final keyboard = XKeyboard.instance;

// Enable swipe-to-dismiss. trackingInset is the height of your input bar.
keyboard.enableInteractiveDismiss(trackingInset: 56);
```

Use `ListenableBuilder` to rebuild when the keyboard height changes:

```dart
Scaffold(
  resizeToAvoidBottomInset: false, // we handle it ourselves
  body: ListenableBuilder(
    listenable: keyboard,
    builder: (context, _) {
      final keyboardHeight = keyboard.height;
      final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
      final bottom = max(keyboardHeight, safeBottom);

      return Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              // Freeze scrolling during interactive dismiss
              physics: keyboard.isTracking
                  ? NeverScrollableScrollPhysics()
                  : null,
              // ...
            ),
          ),
          Container(
            padding: EdgeInsets.only(bottom: 8 + bottom),
            // your input bar
          ),
        ],
      );
    },
  ),
);
```

### API

| Member | Description |
|---|---|
| `XKeyboard.instance` | Singleton instance |
| `.height` | Current keyboard height in logical pixels |
| `.systemHeight` | Last system-reported keyboard height |
| `.isOpen` | Whether the keyboard is visible |
| `.isTracking` | Whether a dismiss pan gesture is active |
| `.enableInteractiveDismiss({trackingInset})` | Enable swipe-to-dismiss |
| `.disableInteractiveDismiss()` | Disable swipe-to-dismiss |
| `addListener` / `removeListener` | Standard `ChangeNotifier` API |

### Key points

- Set `resizeToAvoidBottomInset: false` on your `Scaffold` — otherwise Flutter's built-in
  resize fights with `XKeyboard`
- Use `MediaQuery.viewPaddingOf(context).bottom` for the safe area (not `paddingOf`, which
  is consumed by `Scaffold`)
- Use `max(keyboardHeight, safeBottom)` for bottom padding — the keyboard height includes
  the safe area when open, and `safeBottom` covers the home indicator when closed

## XScreenSources

What a screen share needs from the platform, which `captureMode` splits in two:
`pickerDriven` on macOS, where the app enumerates the displays and windows and
draws the picker itself, and `consentDriven` on Android and iOS, where the
system's own consent surface both asks and chooses. It reads independently of
`supported`, so a consumer builds the right flow per family without platform
checks of its own.

macOS 14 and up, Android 10 and up, iOS 13 and up. `supported` is the platform
family; `available()` adds the OS version, and on iOS ReplayKit's own answer,
which is false while the app is not in front, a mirrored display is attached, or
another recorder holds the screen. A call the family's mode has no role for
throws `unsupported`: `list`, `hasPermission` and `requestPermission` off
`pickerDriven`, `startShare` and `stopShare` off `consentDriven`.

### macOS — the picker

Needs the screen-recording grant, which the app drives itself: `list` never
prompts, `hasPermission` answers without prompting and `requestPermission`
asks. Nothing to install on the host side.

```dart
final sources = XScreenSourcesBackend.instance;
if (!await sources.available()) return;
if (!await sources.hasPermission() && !await sources.requestPermission()) {
  return;
}

final snapshot = await sources.list(
  allowedDisplayIds: {'1'},
  allowedWindowIds: {'27', '31'},
  thumbnailWidth: 320,
  thumbnailHeight: 180,
);
```

The caller passes the ids its capture stack reported and presents exactly what
comes back — each survivor as an `XScreenSource` carrying its id, kind, title,
owning application, source pixel dimensions and an aspect-fit PNG. A source
whose thumbnail fails to render arrives with a null `thumbnailPng`, so one bad
window never costs the picker its list; the call throws `thumbnail_failed` only
when no requested source rendered at all. `XScreenSourcesBackend.instance` is
settable, and `package:ux/testing.dart` vends `FakeXScreenSourcesBackend` for
tests without a host.

### Android — the share bracket

Android grants a capture only while a `mediaProjection` foreground service
runs, and grants that service only once the projection consent is held, so the
bracket goes between the two:

```dart
final sources = XScreenSourcesBackend.instance;
if (!await sources.available()) return;

await captureStack.requestConsent();
await sources.startShare(
  notificationTitle: 'Sharing your screen',
  notificationText: 'Tap to return to the call',
);
await captureStack.startCapture();
// … and on teardown:
await sources.stopShare();
```

Consent and capture are the consumer's own capture stack; `ux` supplies the
service between them. It is declared, with `FOREGROUND_SERVICE` and
`FOREGROUND_SERVICE_MEDIA_PROJECTION`, in `ux`'s own manifest, which merges
into the host app — nothing to add there. A start the platform refuses for want
of consent throws `permission_denied`, any other refusal
`service_start_failed` — as does a start a later `startShare` or a `stopShare`
settles before the hold is up. The hold also drops when the Flutter engine
detaches. The ongoing notification takes the host's
`io.swipelab.ux.notification_icon` meta-data icon, the one `XNotifications`
uses.

### iOS — the share bracket

The same three calls, over ReplayKit's in-app recorder: the consumer's capture
stack starts `RPScreenRecorder`, which raises the consent alert itself and
delivers the frames in-process. The recorder captures the host app's own
display, and only while it is in front — a participant sees this app, not the
device, and the frames stop when the user leaves it. Capturing past the app is
a broadcast upload extension's job, which `getDisplayMedia` selects by a
`broadcast`-prefixed `deviceId` and this arm does not build; nothing here needs
an entry in the host's `Info.plist` or entitlements.

iOS asks for no hold around that capture, so what `startShare` carries is the
recorder's own arbitration — it refuses while the app is not in front, a
mirrored display is attached, or another recorder holds the screen — raised as
`service_start_failed` before the consumer asks for a track that would never
produce a frame. The notification arguments have no iOS role: the system's red
recording indicator is the ongoing surface. `stopShare` holds nothing to drop
and succeeds, so the same consumer code brackets both consent-driven families:

```dart
final sources = XScreenSourcesBackend.instance;
if (!await sources.available()) return;

await sources.startShare(
  notificationTitle: 'Sharing your screen',
  notificationText: 'Tap to return to the call',
);
await captureStack.startCapture();
// … and on teardown:
await sources.stopShare();
```

Consent itself lives inside that capture start, so `startShare` never raises
`permission_denied` on iOS.

## XCameraEffects

None, blur or dim behind the person on the outgoing camera track.

macOS 12 and up, iOS 15 and up, and Android. `supported` is the platform
family; `available()` adds the OS version and whether the host installed its
bridge. Needs the camera grant the host already holds for capture —
`NSCameraUsageDescription`, plus `com.apple.security.device.camera` for a
sandboxed macOS app.

`ux` owns the effect, not the camera: the host app supplies the seam to its own
video stack by conforming to `CameraEffectsBridge` and installing one instance.

```swift
import ux

final class MyCameraEffectsBridge: CameraEffectsBridge {
    func attach(
        trackId: String,
        processing: @escaping (CameraEffectsFrame) -> CameraEffectsFrame
    ) throws -> CameraEffectsAttachment { /* look the track up, add the callback */ }

    func detach(_ attachment: CameraEffectsAttachment) -> CameraEffectsDetachOutcome {
        /* remove that exact callback */
    }

    func teardown() { /* release what the bridge holds */ }
}

CameraEffects.install(MyCameraEffectsBridge())
```

With nothing installed every command answers `integration_unavailable` and
`available()` answers false.

### Quick start

```dart
final effects = XCameraEffectsBackend.instance;
if (!await effects.available()) return;

await effects.setEffect(track.id, XCameraEffect.blur);
// effects.status reaches XCameraEffectPhase.active when effected frames flow
await effects.clear();
```

One track carries an effect at a time. `setEffect` returns once the platform
has taken the command, and `status` reports what the frames are doing —
`idle`, `applying`, `active`, or `failed` when processing stops after the
effect was live. A command that cannot be served throws
`XCameraEffectsException`. `XCameraEffectsBackend.instance` is settable, and
`package:ux/testing.dart` vends `FakeXCameraEffectsBackend`.

## Other utilities

- **BendBox** — a flexible layout widget
- **Bezier** — bezier curve utilities
