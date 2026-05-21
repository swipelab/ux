# ux

A Flutter toolkit for building fluid, native-feeling UIs.

## XKeyboard

Frame-accurate keyboard height tracking for iOS and Android, with interactive dismiss.

Flutter's built-in `MediaQuery.viewInsets.bottom` lags behind the actual keyboard position
and doesn't support interactive dismiss. `XKeyboard` reads the keyboard height directly
from the native layer via FFI — zero channel latency, every frame.

### Features

- **Real-time height** — reads the keyboard's actual position each frame via FFI (iOS) / JNI (Android)
- **Native animation curves** — sampled from `CADisplayLink` (iOS) and `WindowInsetsAnimation` (Android),
  with adaptive learning that refines the curve from observations
- **Interactive dismiss** — swipe the keyboard down like iMessage/Telegram, with snap-back or dismiss
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

## Other utilities

- **BendBox** — a flexible layout widget
- **Bezier** — bezier curve utilities
