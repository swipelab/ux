import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

DynamicLibrary? _open() {
  if (kIsWeb) return null;
  try {
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    if (Platform.isAndroid) return DynamicLibrary.open('libux.so');
  } catch (_) {
    return null;
  }
  return null;
}

/// `null` on web, unsupported platforms, or load failure.
final DynamicLibrary? uxLib = _open();

double Function()? uxLookupDouble(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Double Function()>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

int Function()? uxLookupInt32(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Int32 Function()>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

void Function()? uxLookupVoid(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Void Function()>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

void Function(double)? uxLookupVoidDouble(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Void Function(Double)>>(name).asFunction();
  } catch (_) {
    return null;
  }
}
