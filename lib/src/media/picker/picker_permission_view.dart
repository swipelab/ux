import 'package:flutter/cupertino.dart';
import 'package:ux/gallery.dart';
import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/touch.dart';

/// Camera authorization action alongside the photo library.
class PickerCameraBanner extends StatelessWidget {
  /// Requests access or opens the app's camera Settings.
  const PickerCameraBanner({super.key, required this.onAllow});

  /// The explicit permission action.
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) => _PermissionRow(
    rationale: strings.cameraAccessRationale,
    onPress: onAllow,
  );
}

/// Replaces the library while photo access is unavailable.
class PickerPermissionPlaceholder extends StatelessWidget {
  /// Creates the placeholder for [state].
  const PickerPermissionPlaceholder({
    super.key,
    required this.state,
    required this.onAllow,
    required this.onSettings,
  });

  /// The resolved photo authorization.
  final XGalleryPermission state;

  /// Requests photo access before the first system prompt.
  final VoidCallback onAllow;

  /// Opens Settings after denial or restriction.
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final canPrompt = state == XGalleryPermission.notDetermined;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 196,
              height: 196,
              child: Icon(
                CupertinoIcons.photo_on_rectangle,
                size: 128,
                color: colors.textTertiary,
              ),
            ),
            SizedBox(height: space.lg),
            Text(
              strings.photoAccessTitle,
              textAlign: TextAlign.center,
              style: text.body.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: space.lg * 2),
            _PermissionPill(
              onPress: canPrompt ? onAllow : onSettings,
              label: canPrompt
                  ? strings.allowPhotoAccess
                  : strings.openSettings,
              padding: EdgeInsets.symmetric(
                horizontal: space.lg * 2,
                vertical: space.md,
              ),
              borderRadius: radius.md,
            ),
          ],
        ),
      ),
    );
  }
}

/// Offers the system selector for the accessible subset of photos.
class PickerLimitedBanner extends StatelessWidget {
  /// Creates the banner.
  const PickerLimitedBanner({super.key, required this.onManage});

  /// Opens the limited-library selector.
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) => _PermissionRow(
    rationale: strings.limitedPhotosRationale,
    onPress: onManage,
  );
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.rationale, required this.onPress});

  final String rationale;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: space.lg, right: space.lg, bottom: space.md),
    child: Row(
      children: [
        Expanded(
          child: Text(
            rationale,
            style: text.body.copyWith(color: colors.textSecondary),
          ),
        ),
        SizedBox(width: space.lg),
        _PermissionPill(
          onPress: onPress,
          label: strings.manage,
          borderRadius: radius.pill,
          padding: EdgeInsets.symmetric(
            horizontal: space.md,
            vertical: space.xs,
          ),
        ),
      ],
    ),
  );
}

class _PermissionPill extends StatelessWidget {
  const _PermissionPill({
    required this.onPress,
    required this.label,
    required this.padding,
    required this.borderRadius,
  });

  final VoidCallback onPress;
  final String label;
  final EdgeInsets padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) => Touch(
    onPress: onPress,
    child: Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.brand,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Text(
        label,
        style: text.body.copyWith(
          color: colors.onBrand,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
  );
}
