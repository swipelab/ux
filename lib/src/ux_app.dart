import 'package:flutter/material.dart';

class UxApp extends InheritedWidget {
  final Widget child;

  UxApp({this.child});

  Widget build(BuildContext context) {
    return Stack(
      children: [Positioned.fill(child: child)],
    );
  }

  bool updateShouldNotify(InheritedWidget oldWidget) => false;

  UxApp of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UxApp>();
}

