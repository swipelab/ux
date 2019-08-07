import 'dart:async';

import 'package:flutter/services.dart';

class Ux {
  static const MethodChannel _channel =
      const MethodChannel('ux');

  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }
}
