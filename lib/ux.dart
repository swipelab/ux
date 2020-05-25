library ux;

export 'src/bend_box.dart';
export 'src/json_extension.dart';
export 'src/bezier.dart';

import 'dart:async';
import 'package:flutter/services.dart';

class UX {
  static const MethodChannel _channel = const MethodChannel('ux');

  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }
}