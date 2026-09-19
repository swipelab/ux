import 'package:flutter/widgets.dart';
import 'package:ux/src/media/host.dart';

/// The host's colours.
MediaColors get colors => MediaHost.current.colors;

/// The host's type.
MediaText get text => MediaHost.current.text;

/// The font family of text the flow styles itself.
String get mediaFontFamily => MediaHost.current.text.family;

/// The host's icons.
MediaIcons get icons => MediaHost.current.icons;

/// The host's strings.
MediaStrings get strings => MediaHost.current.strings;

/// The host's insets.
MediaInsets get insets => MediaHost.current.insets;

/// Distances between elements.
const space = MediaSpace();

/// Corner radii.
const radius = MediaRadius();

/// Length of a state change.
const kAnimation = Duration(milliseconds: 190);

/// The distances the media flow lays out with.
class MediaSpace {
  /// Creates the scale.
  const MediaSpace();

  /// 4.
  final double xs = 4;

  /// 8.
  final double sm = 8;

  /// 12.
  final double md = 12;

  /// 16.
  final double lg = 16;

  /// Padding inside a banner pill.
  final EdgeInsets banner = const EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 8,
  );
}

/// The corner radii the media flow rounds with.
class MediaRadius {
  /// Creates the scale.
  const MediaRadius();

  /// 8.
  final double sm = 8;

  /// 12.
  final double md = 12;

  /// 22.
  final double pill = 22;
}
