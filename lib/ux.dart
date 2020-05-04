library ux;

export 'src/bend_box.dart';
export 'src/note.dart';
export 'src/ux_app.dart';
export 'src/json_extension.dart';

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/note.dart';

class UX {
  static const MethodChannel _channel = const MethodChannel('ux');

  static Future<String> get platformVersion async {
    final String version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }
}

extension UxExtension on BuildContext {
  showText<T>(String text,
          {bool modal = false,
          double backdropBlur = 0.0,
          Duration duration = const Duration(seconds: 3)}) =>
      Note<T>(
              duration: duration,
              modalBackdropBlur: backdropBlur,
              isModal: modal,
              child: Container(
                  decoration: BoxDecoration(color: Color(0xFF202020)),
                  child: ListTile(
                      title:
                          Text(text, style: TextStyle(color: Colors.white)))))
          .show(this);
}
