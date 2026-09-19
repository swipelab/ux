import 'package:flutter/widgets.dart';

/// What the media flow reads from the app that hosts it. The app sets
/// [MediaHost.current] before it shows any of the flow.
abstract class MediaHost {
  /// The host in effect.
  static late MediaHost current;

  /// Colours, read on every build so a theme change shows at once.
  MediaColors get colors;

  /// Type.
  MediaText get text;

  /// Icons.
  MediaIcons get icons;

  /// Strings in the app's language.
  MediaStrings get strings;
}

/// The colours the media flow paints with.
abstract class MediaColors {
  /// Foreground over photos, video and the camera.
  Color get onMedia;

  /// A destructive foreground over media.
  Color get onMediaDestructive;

  /// Hint text over media.
  Color get mediaHint;

  /// The app's accent.
  Color get brand;

  /// Foreground on [brand].
  Color get onBrand;

  /// Page background.
  Color get scaffold;

  /// Raised background.
  Color get surface;

  /// Quiet fill behind controls.
  Color get fill;

  /// Dimming behind sheets.
  Color get scrim;

  /// Main text.
  Color get textPrimary;

  /// Supporting text.
  Color get textSecondary;

  /// Faint text.
  Color get textTertiary;

  /// Destructive actions.
  Color get destructive;
}

/// The text styles the media flow sets type in.
abstract class MediaText {
  /// Running text.
  TextStyle get body;

  /// Small running text.
  TextStyle get bodySmall;
}

/// The icons the media flow draws that have no Cupertino equivalent in use.
abstract class MediaIcons {
  /// Video is off.
  IconData get videoOff;

  /// The microphone is off.
  IconData get micSlash;

  /// Sound is muted.
  IconData get volumeXmark;

  /// Sound is on.
  IconData get volumeHigh;
}

/// The strings the media flow shows.
abstract class MediaStrings {
  /// A camera failure with no better description.
  String get cameraError;

  /// The camera could not be reached.
  String get failedToAccessCamera;

  /// The device has no camera.
  String get noCameraFound;

  /// Invites a tap that turns the microphone on.
  String get cameraTapToEnableMic;

  /// Placeholder of the caption field.
  String get addACaption;

  /// Delete.
  String get delete;

  /// Close.
  String get close;
}
