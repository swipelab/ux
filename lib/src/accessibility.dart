import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import 'core/emitter.dart';
import 'log.dart' show Log;

final _log = Log.tag('accessibility');

/// The OS's accessibility settings that Flutter's embedder does not report.
abstract interface class XAccessibility {
  /// The process-wide reader. Swap to inject a fake before anything reads it.
  static XAccessibility instance = MethodChannelXAccessibility();

  /// Whether the OS asks apps to reduce motion.
  ///
  /// - macOS: Reduce motion, `NSWorkspace`'s
  ///   `accessibilityDisplayShouldReduceMotion`.
  /// - Windows: Animation effects off, `SPI_GETCLIENTAREAANIMATION`.
  /// - iOS, Android and Linux: stays `false`, since Flutter's
  ///   `AccessibilityFeatures` carry the setting there (`reduceMotion`,
  ///   `disableAnimations`).
  ValueListenable<bool> get reduceMotion;
}

/// Production [XAccessibility], over `ux/accessibility/events`.
class MethodChannelXAccessibility implements XAccessibility {
  /// Subscribes to the native event channel where one is registered.
  MethodChannelXAccessibility() {
    if (!_hasNativeHandler) return;
    _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (e, st) {
        _log.w('event channel error', error: e, stackTrace: st);
      },
    );
  }

  /// Only macOS and Windows register a native stream handler for the events
  /// channel; activating it elsewhere throws `MissingPluginException`.
  static bool get _hasNativeHandler =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  static const _events = EventChannel('ux/accessibility/events');

  @override
  final ValueEmitter<bool> reduceMotion = ValueEmitter(false);

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final m = event.cast<Object?, Object?>();
    if (m['type'] == 'reduceMotion') {
      final reduced = m['reduced'];
      if (reduced is! bool) return;
      _log.i('reduceMotion: $reduced');
      reduceMotion.value = reduced;
    }
  }
}
