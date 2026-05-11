/// Drains native uncaught-exception JSON records persisted by the platform
/// `CrashPlugin` (iOS / Android) and re-emits them through [Log.f], so they
/// flow out via whatever sink chain `Log.configure` was given (Console + File
/// + Http + …). The drain is a no-op on platforms without a CrashPlugin.
library;

import 'package:flutter/services.dart';

import 'log.dart';

/// Pull persisted native crash records and re-emit them as [Log.f]. Call once
/// during app boot, after `Log.configure(...)`, before [runApp].
class UxCrash {
  UxCrash._();

  static const _channel = MethodChannel('ux/crash');

  /// Drains persisted native crashes from prior runs and re-emits each through
  /// [Log.f]. Each record is acked back to the plugin after successful re-emit
  /// so the underlying file is deleted. Errors talking to the channel are
  /// swallowed — crash drain must never block app start.
  static Future<void> drainAndReport({MethodChannel? channel}) async {
    final ch = channel ?? _channel;
    final List<Object?> raw;
    try {
      final res = await ch.invokeMethod<List<Object?>>('drainPending');
      raw = res ?? const [];
    } on MissingPluginException {
      return;
    } catch (e, st) {
      Log.tag('ux.crash').w('drainPending failed', error: e, stackTrace: st);
      return;
    }

    for (final entry in raw) {
      if (entry is! Map) continue;
      final m = entry.cast<Object?, Object?>();
      final id = m['id']?.toString();
      _report(m);
      if (id == null) continue;
      try {
        await ch.invokeMethod<void>('ackCrash', id);
      } catch (e, st) {
        Log.tag('ux.crash').w('ackCrash failed', error: e, stackTrace: st);
      }
    }
  }

  static void _report(Map<Object?, Object?> m) {
    final platform = m['platform']?.toString() ?? 'native';
    final summary = StringBuffer('native crash ($platform)');
    final type = (m['name'] ?? m['type'])?.toString();
    if (type != null && type.isNotEmpty) {
      summary
        ..write(': ')
        ..write(type);
    }
    final reason = (m['reason'] ?? m['message'])?.toString();
    if (reason != null && reason.isNotEmpty) {
      summary
        ..write(' — ')
        ..write(reason);
    }

    final stack = _stack(m);
    Log.tag('ux.crash').f(
      summary.toString(),
      error: reason ?? type,
      stackTrace: stack,
      fields: {
        for (final k in m.keys)
          if (k != null && _passThrough.contains(k.toString()))
            k.toString(): m[k],
      },
    );
  }

  static StackTrace? _stack(Map<Object?, Object?> m) {
    final stack = m['stack']?.toString();
    if (stack != null && stack.isNotEmpty) return StackTrace.fromString(stack);
    final symbols = m['callStackSymbols'];
    if (symbols is List && symbols.isNotEmpty) {
      return StackTrace.fromString(symbols.join('\n'));
    }
    return null;
  }

  /// Asks the native plugin to raise an uncaught exception, crashing the app.
  /// On the next launch, [drainAndReport] should pick the record up. Intended
  /// for end-to-end testing of the crash pipeline; do not ship buttons that
  /// call this in release builds.
  static Future<void> triggerNativeTestCrash({MethodChannel? channel}) async {
    final ch = channel ?? _channel;
    await ch.invokeMethod<void>('triggerTestCrash');
  }

  static const _passThrough = {
    'id',
    'platform',
    'time',
    'bundleId',
    'packageName',
    'systemVersion',
    'sdkInt',
    'thread',
    'cause',
  };
}
