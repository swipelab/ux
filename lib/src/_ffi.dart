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

/// Binds the zero-arg double-returning native symbol [name], or `null`
/// when it can't be resolved.
double Function()? uxLookupDouble(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Double Function()>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

/// Binds the zero-arg int32-returning native symbol [name], or `null`
/// when it can't be resolved.
int Function()? uxLookupInt32(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Int32 Function()>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

/// Binds the zero-arg void native symbol [name], or `null` when it can't
/// be resolved.
void Function()? uxLookupVoid(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Void Function()>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

/// Binds the double-taking void native symbol [name], or `null` when it
/// can't be resolved.
void Function(double)? uxLookupVoidDouble(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib.lookup<NativeFunction<Void Function(Double)>>(name).asFunction();
  } catch (_) {
    return null;
  }
}

/// Binds `void f(void (*cb)(void))`, or `null` when it can't be resolved.
void Function(Pointer<NativeFunction<Void Function()>>)?
    uxLookupVoidCallback(String name) {
  final lib = uxLib;
  if (lib == null) return null;
  try {
    return lib
        .lookup<
            NativeFunction<
                Void Function(Pointer<NativeFunction<Void Function()>>)>>(name)
        .asFunction();
  } catch (_) {
    return null;
  }
}
