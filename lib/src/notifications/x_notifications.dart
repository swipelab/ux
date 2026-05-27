import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';

import '../core/emitter.dart';
import '../log.dart' show Log;

final _log = Log.tag('notifications');

/// Generic OS-notification + window-focus surface. Domain-agnostic — the
/// caller decides when to emit and how to format the payload. Implemented
/// on macOS via `UNUserNotificationCenter` and NSWindow key-focus
/// observers (see `macos/Classes/NotificationsPlugin.swift`).
abstract interface class XNotifications {
  /// Production singleton — talks to the native plugin via MethodChannel
  /// + EventChannel. Tests inject a fake `XNotifications` directly into
  /// their service-under-test rather than swap this field.
  static final XNotifications instance = MethodChannelXNotifications();

  /// True when the host window currently holds key focus. Defaults to
  /// `true` until the native side emits an initial focus event.
  ValueListenable<bool> get windowFocused;

  /// `null` = OS hasn't been asked; `true`/`false` after the user has
  /// answered an authorization prompt.
  ValueListenable<bool?> get authorized;

  /// Tap events. Payload is the `data` Map supplied to [show].
  Stream<Map<String, String>> get onTap;

  Future<bool> requestPermission();

  /// Posts (or replaces) a system notification. Same [XNotification.id]
  /// replaces any prior notification with that id. [XNotification.threadId]
  /// groups multiple notifications in the OS's notification UI.
  Future<void> show(XNotification n);

  Future<void> cancelByThread(String threadId);
  Future<void> cancelAll();
}

class MethodChannelXNotifications implements XNotifications {
  MethodChannelXNotifications() {
    _eventsChannel.receiveBroadcastStream().listen(_onEvent, onError: (e, st) {
      _log.w('event channel error', error: e, stackTrace: st);
    });
  }

  static const _channel = MethodChannel('ux/notifications');
  static const _eventsChannel = EventChannel('ux/notifications/events');

  @override
  final ValueEmitter<bool> windowFocused = ValueEmitter(true);

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
      await _channel
          .invokeMethod('cancelByThread', {'threadId': threadId});
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
      case 'focus':
        final f = m['focused'];
        if (f is bool) windowFocused.value = f;
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

class XNotification {
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

  final String title;
  final String body;

  /// Groups notifications in the OS UI (macOS Notification Center
  /// collapses entries sharing a `threadIdentifier`).
  final String? threadId;

  /// Delivered verbatim to the tap event when the user clicks the
  /// notification.
  final Map<String, String> data;
}
