library scoped;

import 'dart:async';
import 'package:flutter/services.dart';

export 'src/bend_box.dart';

class Ux {
  static const MethodChannel _channel =
      const MethodChannel('ux');

  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }
}
