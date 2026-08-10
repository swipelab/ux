import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../core/emitter.dart';
import '../log.dart' show Log;

final _log = Log.tag('notifications');

/// OS-notification primitive. Domain-agnostic — the caller decides when
/// to emit and how to format the payload. Backed natively on macOS
/// (`UNUserNotificationCenter`) and Android (`NotificationManagerCompat`);
/// see the platform `NotificationsPlugin`. No handler on iOS, where calls
/// no-op. Window-focus state lives in [XWindow], not here.
abstract interface class XNotifications {
  /// Production singleton — talks to the native plugin via MethodChannel
  /// + EventChannel. Tests inject a fake `XNotifications` directly into
  /// their service-under-test rather than swap this field.
  static final XNotifications instance = MethodChannelXNotifications();

  /// `null` = OS hasn't been asked; `true`/`false` after the user has
  /// answered an authorization prompt.
  ValueListenable<bool?> get authorized;

  /// Tap events. Payload is the `data` Map supplied to [show].
  Stream<Map<String, String>> get onTap;

  /// Prompts for notification authorization and reports whether it was
  /// granted.
  Future<bool> requestPermission();

  /// Posts (or replaces) a system notification. Same [XNotification.id]
  /// replaces any prior notification with that id. [XNotification.threadId]
  /// groups multiple notifications in the OS's notification UI.
  Future<void> show(XNotification n);

  /// Withdraws every posted notification sharing [threadId].
  Future<void> cancelByThread(String threadId);

  /// Withdraws every notification this app has posted.
  Future<void> cancelAll();
}

/// Production [XNotifications], over the `ux/notifications` channels.
class MethodChannelXNotifications implements XNotifications {
  /// Subscribes to the native event channel where one is registered.
  MethodChannelXNotifications() {
    if (!_hasNativeHandler) return;
    _eventsChannel.receiveBroadcastStream().listen(_onEvent, onError: (e, st) {
      _log.w('event channel error', error: e, stackTrace: st);
    });
  }

  /// Only macOS and Android register a native handler; activating the events
  /// channel elsewhere throws `MissingPluginException`.
  static bool get _hasNativeHandler =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.android;

  static const _channel = MethodChannel('ux/notifications');
  static const _eventsChannel = EventChannel('ux/notifications/events');

  @override
  final ValueEmitter<bool?> authorized = ValueEmitter(null);

  @override
  Stream<Map<String, String>> get onTap => _onTap.stream;
  final StreamController<Map<String, String>> _onTap =
      StreamController<Map<String, String>>.broadcast();

  @override
  Future<bool> requestPermission() async {
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestPermission') ?? false;
      authorized.value = granted;
      return granted;
    } on PlatformException catch (e) {
      _log.w('requestPermission failed: ${e.message}');
      authorized.value = false;
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> show(XNotification n) async {
    try {
      await _channel.invokeMethod('show', {
        'id': n.id,
        'title': n.title,
        'body': n.body,
        if (n.threadId != null) 'threadId': n.threadId,
        'data': n.data,
      });
    } on PlatformException catch (e) {
      _log.w('show failed: ${e.message}');
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<void> cancelByThread(String threadId) async {
    try {
      await _channel.invokeMethod('cancelByThread', {'threadId': threadId});
    } on PlatformException catch (e) {
      _log.w('cancelByThread failed: ${e.message}');
    } on MissingPluginException {
      return;
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod('cancelAll');
    } on PlatformException catch (e) {
      _log.w('cancelAll failed: ${e.message}');
    } on MissingPluginException {
      return;
    }
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final m = event.cast<Object?, Object?>();
    switch (m['type']) {
      case 'authorization':
        final g = m['granted'];
        if (g is bool) authorized.value = g;
      case 'tap':
        final raw = m['data'];
        final data = raw is Map
            ? Map<String, String>.fromEntries(
                raw.entries.map((e) =>
                    MapEntry(e.key.toString(), e.value?.toString() ?? '')),
              )
            : <String, String>{};
        _onTap.add(data);
    }
  }
}

/// One system notification to post through [XNotifications.show].
class XNotification {
  /// Binds the notification's identity to the text the OS displays.
  XNotification({
    required this.id,
    required this.title,
    required this.body,
    this.threadId,
    this.data = const {},
  });

  /// Stable identifier; posting another notification with the same id
  /// replaces the existing one (typical use: id = chat/thread id so the
  /// latest preview from a chat replaces the older toast).
  final String id;

  /// Headline the OS displays.
  final String title;

  /// Body text below [title].
  final String body;

  /// Groups notifications in the OS UI (macOS Notification Center
  /// collapses entries sharing a `threadIdentifier`).
  final String? threadId;

  /// Delivered verbatim to the tap event when the user clicks the
  /// notification.
  final Map<String, String> data;
}
