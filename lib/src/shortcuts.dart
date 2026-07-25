import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// One donated shortcut — a conversation, a document, whatever the app wants
/// the OS to offer as a shortcut and a Direct Share target.
class XShortcutTarget {
  const XShortcutTarget({
    required this.id,
    required this.label,
    this.iconPath,
  });

  /// Stable identifier. The share sheet hands it back to the target activity
  /// as `EXTRA_SHORTCUT_ID`, so it should be whatever the app routes on.
  final String id;

  /// Short, user-facing name.
  final String label;

  /// Absolute path of an image to use as the icon — masked to a circle by the
  /// launcher. A missing or undecodable file falls back to the app icon.
  final String? iconPath;

  Map<String, Object?> toMap() => {
        'id': id,
        'label': label,
        'iconPath': iconPath,
      };
}

/// Android dynamic shortcuts: the long-press menu on the launcher icon, and —
/// with a matching `<share-target>` in the app's `share-targets.xml` — the
/// **Direct Share** row of the system share sheet.
///
/// Android-only. Apple's nearest equivalent is intent donation
/// (`INSendMessageIntent`), which is not a shortcut and belongs to the app.
class XShortcuts {
  XShortcuts._();

  static const _channel = MethodChannel('ux/shortcuts');

  static bool get supported => Platform.isAndroid;

  /// Replaces the dynamic shortcut set with [targets], ranked in list order.
  /// The OS caps how many it keeps; extras past the cap are dropped.
  ///
  /// [category] must be the category the app's `<share-target>` declares —
  /// the share sheet matches the two, and a mismatch simply shows nothing.
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

  /// Drops every donated shortcut — logout, account switch.
  static Future<void> clear() async {
    if (!supported) return;
    await _channel.invokeMethod<void>('clear');
  }
}
