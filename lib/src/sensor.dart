import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

DynamicLibrary? _initLib() {
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isAndroid) return DynamicLibrary.open('libux_keyboard.so');
  return null;
}

final DynamicLibrary? _lib = _initLib();

int Function()? _lookupInt32(String name) {
  if (_lib == null) return null;
  try {
    return _lib!.lookup<NativeFunction<Int32 Function()>>(name).asFunction<int Function()>();
  } catch (_) {
    return null;
  }
}

final _uxDeviceOrientation = _lookupInt32('ux_device_orientation');

class UxSensor {
  UxSensor._();

  /// Accelerometer-driven physical device rotation; updates regardless of
  /// OS auto-rotate or app UI orientation lock.
  static DeviceOrientation get orientation {
    final idx = _uxDeviceOrientation?.call() ?? 0;
    if (idx < 0 || idx >= DeviceOrientation.values.length) {
      return DeviceOrientation.portraitUp;
    }
    return DeviceOrientation.values[idx];
  }

  /// Lazily-created listenable backing [orientationListenable].
  static _OrientationNotifier? _orientationNotifier;

  /// Listenable form of [orientation], updated as the device rotates.
  /// Backed by a Dart-side 100ms poll of the underlying FFI getter.
  static ValueListenable<DeviceOrientation> get orientationListenable {
    return _orientationNotifier ??= _OrientationNotifier();
  }
}

class _OrientationNotifier extends ChangeNotifier
    implements ValueListenable<DeviceOrientation> {
  _OrientationNotifier() : _value = UxSensor.orientation;

  Timer? _timer;
  DeviceOrientation _value;

  @override
  DeviceOrientation get value => _value;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(const Duration(milliseconds: 100), _tick);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick(Timer _) {
    final next = UxSensor.orientation;
    if (next != _value) {
      _value = next;
      notifyListeners();
    }
  }
}
