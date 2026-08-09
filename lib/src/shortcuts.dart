import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One donated target — a conversation, a document, whatever the app wants
/// the OS to offer in the share sheet.
class XShortcutTarget {
  /// Binds the target's routing id to what the share sheet shows.
  const XShortcutTarget({
    required this.id,
    required this.label,
    this.iconPath,
  });

  /// Stable identifier. The share sheet hands it back as `EXTRA_SHORTCUT_ID`
  /// (Android) or as the donated intent's `conversationIdentifier` (iOS), so
  /// it should be whatever the app routes on.
  final String id;

  /// Short, user-facing name.
  final String label;

  /// Absolute path of an image to use as the icon — masked to a circle by the
  /// launcher. A missing or undecodable file falls back to the app icon.
  final String? iconPath;

  /// This target in the channel's wire shape.
  Map<String, Object?> toMap() => {
        'id': id,
        'label': label,
        'iconPath': iconPath,
      };
}

/// The per-conversation targets the system share sheet offers above the app
/// row — Android's **Direct Share**, iOS's share suggestions.
///
/// Two unrelated OS mechanisms behind one surface: Android donates *dynamic
/// shortcuts* (which also fill the launcher icon's long-press menu, and need a
/// matching `<share-target>` in the app's `share-targets.xml`), iOS donates
/// *`INSendMessageIntent` interactions* to SiriKit and lets the system decide
/// what to suggest. macOS has no equivalent.
class XShortcuts {
  XShortcuts._();

  static const _channel = MethodChannel('ux/shortcuts');

  /// Whether this platform offers per-conversation share targets.
  static bool get supported =>
      debugSupported ?? (Platform.isAndroid || Platform.isIOS);

  /// Forces [supported] on a host that has no share targets, so a consumer's
  /// tests can exercise [donate]/[clear] against a mock `ux/shortcuts`
  /// handler instead of skipping the code path entirely.
  @visibleForTesting
  static bool? debugSupported;

  /// Replaces the donated set with [targets], ranked in list order. The OS
  /// caps how many it keeps; extras past the cap are dropped.
  ///
  /// [category] is Android-only: it must be the category the app's
  /// `<share-target>` declares — the share sheet matches the two, and a
  /// mismatch simply shows nothing. iOS ignores it.
  static Future<void> donate({
    required List<XShortcutTarget> targets,
    required String category,
  }) async {
    if (!supported) return;
    await _channel.invokeMethod<void>('donate', {
      'targets': [for (final t in targets) t.toMap()],
      'category': category,
    });
  }

  /// Drops every donated target — logout, account switch.
  static Future<void> clear() async {
    if (!supported) return;
    await _channel.invokeMethod<void>('clear');
  }
}
