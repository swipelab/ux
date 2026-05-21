import 'package:flutter/widgets.dart';

import 'package:ux/src/core/dispose.dart';
import 'package:ux/src/core/list_emitter.dart';
import 'package:ux/src/navi/screen.dart';
import 'package:ux/src/navi/screen_host.dart';
import 'package:ux/src/navi/screen_stack.dart';
import 'package:ux/src/navi/transitions.dart';
import 'package:ux/src/anim/sheet.dart';

/// Screen mixin that presents its content as a half-sheet with full
/// telegram-style physics (drag-to-expand, drag-to-dismiss with spring
/// snap, scroll coordination via [SheetController]) and a nested
/// navigation stack inside the modal — same pattern as telegram-iOS's
/// `AttachmentController` hosting a `NavigationContainer`.
///
/// The screen-stack's transition animation is set to instant
/// (`ScreenTransitions.none`) — the [Sheet] widget self-manages its
/// own slide-up entry / exit using its internal animation controller.
/// This keeps the route layer thin while preserving the full physics
/// model from `~/projects/ciao/app/lib/widgets/sheet.dart`.
///
/// Inside the sheet, [host] resolves to this sheet's own
/// [nestedHost], so `host?.push(SomePage())` from the body lands in
/// a nested `ScreenStack` rendered inside the sheet's bounds (slides
/// in from the right). The original parent host that pushed this
/// sheet is reachable as [parentHost] for rare escape cases.
///
/// Typical use:
///
/// ```dart
/// class MyPage with Screen<Result>, SheetScreen<Result>, Emitter {
///   @override
///   double get sheetCollapsedExtent => 0.55;
///
///   @override
///   Widget buildSheetBody(BuildContext context) => /* page content */;
/// }
///
/// // Pushing within the sheet:
/// final picked = await host?.push(SubPage());
/// ```
mixin SheetScreen<T> on Screen<T> {
  /// Initial height as a fraction of the viewport (0.0–1.0).
  /// Defaults to 0.55 — telegram's standard half-sheet.
  double get sheetCollapsedExtent => 0.55;

  /// Whether the backdrop tap and drag-down past threshold dismiss
  /// the sheet. When false, only programmatic [pop] closes it.
  bool get sheetIsDismissible => true;

  /// When true, the sheet enters at full screen and never collapses.
  /// Drag-to-dismiss is gated to a higher distance threshold.
  bool get sheetIsFullSize => false;

  /// Backdrop scrim color. Sheet fades alpha from 0 (offscreen) to
  /// `barrierColor.a` (fully collapsed).
  Color get sheetBarrierColor => const Color(0x8C000000);

  /// Sheet background. Override for theme-driven colors.
  Color? get sheetBackgroundColor => null;

  /// Top-corner radius. Bottom corners shrink toward 0 as the sheet
  /// expands.
  double get sheetBorderRadius => 16.0;

  /// Scroll-coordination controller. Inner scroll views attach via
  /// `SheetController.attach(scrollController)` and use
  /// `controller.physics` so the sheet drag and the list scroll
  /// hand off cleanly at scroll-top.
  late final SheetController sheetController = SheetController();

  /// Override to provide the sheet's content. Renders below the
  /// drag-handle pill (`SheetThumb`) as the home of the sheet's
  /// nested navigation stack.
  Widget buildSheetBody(BuildContext context);

  /// Inner navigation host for this sheet's nested stack. Pushes
  /// from inside the sheet body land here.
  late final _SheetNestedHost _nestedHost = _SheetNestedHost();

  /// Public-typed view of the sheet's nested host.
  ScreenHost get nestedHost => _nestedHost;

  // ── Screen<T> overrides ────────────────────────────────────────────

  /// Pushes from inside this sheet body target the nested stack,
  /// not the parent host that pushed the sheet. Use [parentHost]
  /// (inherited from `Screen`) to escape the modal — rare.
  @override
  ScreenHost? get host => _nestedHost;

  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) =>
      ScreenTransitions.none(context, animation, child);

  /// Zero-duration route transition — the [Sheet] widget self-manages
  /// its slide-up entry via its own internal animation controller.
  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPresenter(BuildContext context) {
    return Sheet(
      controller: sheetController,
      collapsedExtent: sheetCollapsedExtent,
      isFullSize: sheetIsFullSize,
      isDismissible: sheetIsDismissible,
      barrierColor: sheetBarrierColor,
      backgroundColor: sheetBackgroundColor,
      borderRadius: sheetBorderRadius,
      onDismiss: pop,
      // Fresh `_SheetBody` per rebuild is fine — `ScreenStack`
      // reconciles `home` by type+key.
      child: ListenableBuilder(
        listenable: _nestedHost.pages,
        builder: (context, _) => ScreenStack(
          home: _SheetBody(this),
          stack: [..._nestedHost.pages],
        ),
      ),
    );
  }

  /// System back / iOS edge swipe pops the innermost nested page
  /// first. With the nested stack empty, falls through to the
  /// default `handleBack` (which pops the sheet itself).
  @override
  bool handleBack() {
    if (_nestedHost.pages.isNotEmpty) {
      _nestedHost.pages.last.pop();
      return true;
    }
    return super.handleBack();
  }

  @override
  void onRemoved() {
    super.onRemoved();
    // Tear down any still-mounted nested entries when the sheet is
    // dismissed (drag, backdrop tap, programmatic pop).
    for (final page in _nestedHost.pages.toList()) {
      page.pop();
    }
    _nestedHost.dispose();
  }
}

class _SheetNestedHost with Dispose implements ScreenHost {
  final pages = ListEmitter<Screen>();

  @override
  Future<R?> push<R>(Screen<R> page) {
    page.parentHost = this;
    page.detach = () => pages.removeWhere((p) => identical(p, page));
    page.removed = () => Dispose.object(page);
    page.onPush();
    pages.add(page);
    return page.future;
  }

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }
}

/// Adapter that exposes [SheetScreen.buildSheetBody] as the nested
/// `ScreenStack`'s `home`.
class _SheetBody with Screen<void> {
  _SheetBody(this.sheet);
  final SheetScreen sheet;

  @override
  Widget buildPresenter(BuildContext context) =>
      sheet.buildSheetBody(context);
}
