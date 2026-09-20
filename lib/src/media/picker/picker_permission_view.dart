import 'package:ux/src/media/design.dart';
import 'package:flutter/cupertino.dart';
import 'package:ux/gallery.dart';
import 'package:ux/src/media/touch.dart';

/// Full-screen photo-permission placeholder shown when access is
/// `notDetermined` or `denied` / `restricted`. Mirrors telegram-iOS's
/// `MediaPickerPlaceholderNode` (`MediaPickerPlaceholderNode.swift:11`):
/// icon area, single-line title, multi-line body, single rounded
/// action button. Telegram uses a `Photos.tgs` Lottie in the icon
/// slot — banlu stands in with a static glyph until Lottie lands.
class PickerPermissionPlaceholder extends StatelessWidget {
  /// Creates the placeholder for [state].
  const PickerPermissionPlaceholder({
    super.key,
    required this.state,
    required this.onAllow,
    required this.onSettings,
  });

  /// The photo access; absent before it is known.
  final XGalleryPermission? state;

  /// Triggered when the placeholder shows the `Allow Access` button —
  /// i.e. the system has never been asked yet (`notDetermined`).
  /// Should call `XGallery.requestPermission()`.
  final VoidCallback onAllow;

  /// Triggered when the placeholder shows the `Open Settings` button —
  /// access was previously denied or is restricted, so re-prompting
  /// inline isn't possible.
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final canPrompt = state == XGalleryPermission.notDetermined ||
        state == null;
    final buttonLabel = canPrompt ? 'Allow Access' : 'Open Settings';
    final action = canPrompt ? onAllow : onSettings;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.photo_on_rectangle,
              size: 96,
              color: colors.textTertiary,
            ),
            SizedBox(height: space.md),
            Text(
              'Allow Access to Your Photos',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: space.sm),
            Text(
              'Tap $buttonLabel to grant access to your photos.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 15,
              ),
            ),
            SizedBox(height: space.lg),
            Touch(
              onPress: action,
              child: Container(
                width: 248,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.brand,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Text(
                  buttonLabel,
                  style: TextStyle(
                    color: colors.onBrand,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-edge banner shown when access is `limited` (iOS 14+) — the user
/// granted access to a selected subset of photos. Tap `MANAGE` to
/// re-open the system selector via `XGallery.presentLimitedLibraryPicker()`.
/// Mirrors `MediaPickerManageNode` (`MediaPickerManageNode.swift:8`).
class PickerLimitedBanner extends StatelessWidget {
  /// Creates the banner.
  const PickerLimitedBanner({super.key, required this.onManage});

  /// Called on a tap of the manage action.
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surface,
      padding: EdgeInsets.symmetric(
        horizontal: space.md,
        vertical: space.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              "You've allowed access to a select number of photos.",
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          SizedBox(width: space.md),
          Touch(
            onPress: onManage,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: space.md,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: colors.brand,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'MANAGE',
                style: TextStyle(
                  color: colors.onBrand,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
