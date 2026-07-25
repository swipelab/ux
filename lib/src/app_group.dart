import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Apple App Group containers — the shared filesystem root an app and its
/// extensions (share, notification service, widgets) both mount.
///
/// The group id must be listed in every participating target's
/// `com.apple.security.application-groups` entitlement; without it the
/// lookup yields null rather than failing loudly, so callers that require
/// the container should treat null as a build misconfiguration.
class XAppGroup {
  XAppGroup._();

  static const _channel = MethodChannel('ux/app_group');

  /// Whether this platform has app groups at all — iOS and macOS.
  static bool get supported => Platform.isIOS || Platform.isMacOS;

  /// Absolute path of the container directory shared by every target
  /// entitled for [groupId]
  /// (`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`).
  ///
  /// Null on non-Apple platforms and when the calling target isn't
  /// entitled for [groupId]. The directory itself is created by the OS;
  /// subdirectories are the caller's to make.
  static Future<String?> containerPath(String groupId) async {
    if (!supported) return null;
    return _channel.invokeMethod<String>('containerPath', {
      'groupId': groupId,
    });
  }
}
