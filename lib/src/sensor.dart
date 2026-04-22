import 'dart:ffi';
import 'dart:io';

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
}
