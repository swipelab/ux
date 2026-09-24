import 'package:flutter/widgets.dart';
import 'package:ux/media.dart';
import 'package:ux/ux.dart';

class FakeMediaHost
    implements MediaHost, MediaColors, MediaText, MediaIcons, MediaStrings {
  @override
  MediaColors get colors => this;
  @override
  MediaText get text => this;
  @override
  MediaIcons get icons => this;
  @override
  MediaStrings get strings => this;
  @override
  MediaInsets get insets => _insets;
  final _insets = FakeMediaInsets();

  @override
  final ValueNotifier<AppLifecycleState> lifecycle = ValueNotifier(
    AppLifecycleState.resumed,
  );

  @override
  bool isWideScreen(BuildContext context) => false;

  @override
  Future<T?> push<T>(Screen<T> screen) async => null;

  @override
  TextEditingController captionController() => TextEditingController();

  @override
  Widget confirmButton({required VoidCallback onPressed}) =>
      GestureDetector(onTap: onPressed, child: const Text('Confirm'));

  @override
  Widget captionField({
    required GlobalKey bubbleKey,
    required TextEditingController controller,
    required FocusNode focusNode,
    required VoidCallback onSubmit,
    required String placeholder,
  }) => EditableText(
    key: bubbleKey,
    controller: controller,
    focusNode: focusNode,
    style: const TextStyle(),
    cursorColor: const Color(0xFFFFFFFF),
    backgroundCursorColor: const Color(0xFFFFFFFF),
    onSubmitted: (_) => onSubmit(),
  );

  @override
  Widget keyboardInsets({
    required Widget Function(BuildContext context, double bottom) builder,
  }) => Builder(builder: (context) => builder(context, 0));

  @override
  Color get onMedia => const Color(0xFFFFFFFF);
  @override
  Color get onMediaDestructive => const Color(0xFFFF3B30);
  @override
  Color get mediaHint => const Color(0x99FFFFFF);
  @override
  Color get brand => const Color(0xFF0A84FF);
  @override
  Color get onBrand => const Color(0xFFFFFFFF);
  @override
  Color get scaffold => const Color(0xFF000000);
  @override
  Color get surface => const Color(0xFF1C1C1E);
  @override
  Color get fill => const Color(0xFF2C2C2E);
  @override
  Color get scrim => const Color(0x8C000000);
  @override
  Color get textPrimary => const Color(0xFFFFFFFF);
  @override
  Color get textSecondary => const Color(0xFF8E8E93);
  @override
  Color get textTertiary => const Color(0xFF636366);
  @override
  Color get destructive => const Color(0xFFFF3B30);

  @override
  String get family => 'Roboto';
  @override
  TextStyle get body => const TextStyle(fontSize: 16);
  @override
  TextStyle get bodySmall => const TextStyle(fontSize: 13);

  @override
  IconData get videoOff => const IconData(0xe000);
  @override
  IconData get micSlash => const IconData(0xe001);
  @override
  IconData get volumeXmark => const IconData(0xe002);
  @override
  IconData get volumeHigh => const IconData(0xe003);

  @override
  String get cameraError => 'Camera error';
  @override
  String get failedToAccessCamera => 'Failed to access camera';
  @override
  String get noCameraFound => 'No camera found';
  @override
  String get cameraTapToEnableMic => 'Tap to enable microphone';
  @override
  String get cameraAccessRationale =>
      'Allow camera access to take photos and videos.';
  @override
  String get photoAccessTitle => 'Access Your Photos';
  @override
  String get allowPhotoAccess => 'Allow Photos';
  @override
  String get openSettings => 'Open Settings';
  @override
  String get limitedPhotosRationale =>
      "You've allowed access to selected photos.";
  @override
  String get manage => 'Manage';
  @override
  String get addACaption => 'Add a caption';
  @override
  String get delete => 'Delete';
  @override
  String get close => 'Close';
}

class FakeMediaInsets extends ChangeNotifier implements MediaInsets {
  @override
  EdgeInsets viewPadding = EdgeInsets.zero;
  @override
  double keyboardInset = 0;
}
