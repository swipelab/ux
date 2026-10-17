import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ux/src/core/dispose.dart';
import 'package:ux/src/core/emitter.dart';
import 'package:ux/src/core/functional.dart';
import 'package:ux/src/core/list_emitter.dart';
import 'package:ux/src/core/store/store.dart';
import 'package:ux/src/core/uri.dart';
import 'package:ux/src/navi/screen_host.dart';
import 'package:ux/src/navi/screen_stack.dart';
import 'package:ux/src/navi/screen.dart';

/// Generic stack-based screen router.
///
/// Manages a [home] screen and a [stack] of pushed screens, rendering them
/// via [ScreenStack]. Subclass and override [pages] to add guards
/// (e.g. auth checks) before the default screen list.
class XRouter extends BackButtonDispatcher
    with Dispose, ScreenShell
    implements ScreenHost {
  /// Binds the screen at the bottom of the stack and the optional parser
  /// that turns platform routes into screens.
  XRouter({
    required this.home,
    this.routeParser,
    this.keepKeyboardInsets = false,
  }) {
    home.parentHost = this;
    _updateActive();
  }

  /// The screen below everything on [stack]; it is never popped.
  final Screen home;

  /// Turns platform route information into screens. Without one the router
  /// takes no deep links.
  final RouteInformationParser<Object>? routeParser;

  PlatformRouteInformationProvider? _routeInformationProvider;

  /// Feeds the platform's route information — the launch intent's route on
  /// cold start and warm `pushRouteInformation` events — into the [Router].
  /// Null without a [routeParser]: a route can't become a screen there, and
  /// Flutter's [Router] only accepts a provider alongside a parser.
  PlatformRouteInformationProvider? get routeInformationProvider {
    if (routeParser == null) return null;
    final existing = _routeInformationProvider;
    if (existing != null) return existing;
    final provider = PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(
        uri: Uri.parse(
          WidgetsBinding.instance.platformDispatcher.defaultRouteName,
        ),
      ),
    );
    addDispose(provider.dispose);
    return _routeInformationProvider = provider;
  }

  /// Whether screens see the keyboard in `MediaQuery.viewInsets.bottom`.
  ///
  /// Off by default: a host that drives its bottom-anchored UI from
  /// [XKeyboard] wants the raw inset gone, or the two move the same pixels
  /// twice. Turn it on where [XKeyboard] is unavailable — notably inside an
  /// app extension, which links neither its FFI nor its channel — and the
  /// ordinary `Scaffold`-style `viewInsets` arithmetic works instead.
  final bool keepKeyboardInsets;

  /// Screens pushed above [home], bottom to top.
  late final stack = ListEmitter<Screen>()..disposeBy(this);

  /// The delegate handed to Flutter's [Router].
  late final delegate = XRouterDelegate(router: this);

  /// The back-button dispatcher handed to Flutter's [Router].
  late final backDispatcher = XRouterBack(router: this);

  final _screens = GlobalKey<ScreenStackState>();

  /// The screen most recently fired `onActive`. Used to de-duplicate and
  /// pair active/inactive transitions when the topmost visible screen
  /// changes.
  Screen? _active;

  /// Recomputes the topmost visible screen and fires onInactive/onActive
  /// when it has changed. Topmost is the last non-popped entry in [pages],
  /// which already expands ScreenShell hosting. Also re-applies the
  /// topmost screen's [Screen.supportedOrientations] to the OS, mirroring
  /// UIKit's per-VC `supportedInterfaceOrientations` unwind on pop.
  void _updateActive() {
    Screen? top;
    for (final page in pages.reversed) {
      if (!page.popped) {
        top = page;
        break;
      }
    }
    if (identical(top, _active)) return;
    _active?.onInactive();
    _active = top;
    top?.onActive();
    SystemChrome.setPreferredOrientations(
      (top?.supportedOrientations ?? DeviceOrientation.values).toList(),
    );
  }

  /// The screen a route restore would name: the top of [stack], else [home].
  Screen? get currentConfiguration => stack.lastOrNull ?? home;

  Iterable<Screen> _expand(Screen page) sync* {
    yield page;
    if (page is ScreenShell) {
      for (final screen in (page as ScreenShell).pages) {
        if (!screen.popped) yield screen;
      }
    }
  }

  /// Every screen shown, bottom to top, with each [ScreenShell]'s shown
  /// screens flattened in above it. Override to gate the list — for
  /// instance to substitute an auth screen for [home].
  @override
  List<Screen> get pages => [
    ..._expand(home),
    for (final page in stack) ..._expand(page),
  ];

  /// Every screen the router holds: [pages], with the hidden screens of
  /// each [ScreenShell] among them listed after that shell.
  @override
  List<Screen> get hosted => _withHidden(pages);

  List<Screen> _withHidden(List<Screen> shown) => [
    for (final page in shown) ...[
      page,
      if (page case final ScreenShell shell)
        for (final screen in shell.hosted)
          if (!screen.popped && !shell.pages.contains(screen)) screen,
    ],
  ];

  /// Re-renders [pages] and recomputes the active screen, the system-back
  /// state and the orientations.
  @override
  void pagesChanged() {
    delegate.notifyListeners();
    _updateActive();
  }

  /// Whether back has something to go back to in the app: the screen
  /// [XRouterBack] takes it to, where its [Screen.canPop] holds; or, where it
  /// takes back to the bottom screen of [pages], a screen shown beside that
  /// one. After each frame in which it changes, the router hands it to
  /// [SystemNavigator.setFrameworkHandlesBack].
  bool get canPop => _screens.currentState?.canPop ?? false;

  Widget _buildContent(BuildContext context) {
    // [pages] (not the [home]/[stack] fields) so subclasses can
    // override for gating — e.g. swap home to an auth screen.
    final shown = pages;
    final screens = _withHidden(shown);
    final shells = <Screen, ScreenShell>{
      for (final page in shown)
        if (page case final ScreenShell shell)
          for (final screen in shell.hosted) screen: shell,
    };
    final content = Material(
      child: NotificationListener<NavigationNotification>(
        onNotification: (_) {
          SystemNavigator.setFrameworkHandlesBack(canPop);
          return true;
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => backDispatcher.didPopRoute(),
            ),
          },
          child: ScreenStack(
            key: _screens,
            home: screens.first,
            stack: screens.sublist(1),
            hidden: {...screens}..removeAll(shown),
            beside: {
              for (final MapEntry(key: screen, value: shell) in shells.entries)
                if (shell.isBeside(screen)) screen,
            },
            place: (context, screen, slot) =>
                shells[screen]?.place(context, screen, slot) ?? slot,
          ),
        ),
      ),
    );
    if (keepKeyboardInsets) return content;
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: content,
    );
  }

  /// Builds the router's overlay, holding the current [pages].
  Widget build(BuildContext context) =>
      Overlay.wrap(child: Builder(builder: _buildContent));

  /// Pops everything above [home], including [home]'s hosted screens.
  void popAll() {
    while (stack.isNotEmpty) {
      stack.last.pop();
    }
    if (home is ScreenShell) {
      for (final screen in (home as ScreenShell).hosted.toList()) {
        screen.pop();
      }
    }
  }

  /// Push [page] onto the router.
  ///
  /// If an `==`-equal page is already mounted (hosted by [home], shown or
  /// hidden, or anywhere on [stack]), pops every stack entry above it, asks
  /// [home] to [ScreenShell.show] it when [home] hosts it, and returns
  /// that existing page's future — the caller awaits until the mounted
  /// page is popped. No duplicate is created, no fresh instance is
  /// mounted. For identity-equal screens (no `==` override), this dedup
  /// path is unreachable; behavior matches the pre-dedup semantics.
  ///
  /// The type parameter `T` on the awaiter may differ from the mounted
  /// page's original `T`; the returned future is cast. Pushing an equal
  /// page of a different `T` is undefined.
  @override
  Future<T?> push<T>(Screen<T> page) async {
    if (home == page) {
      FocusManager.instance.primaryFocus?.unfocus();
      popAll();
      return SynchronousFuture(null);
    }

    final top = stack.lastOrNull ?? home;
    final beside = top is ScreenShell && (top as ScreenShell).isBeside(page);
    if (!beside) FocusManager.instance.primaryFocus?.unfocus();

    final existing = _findMounted(page);
    if (existing != null) {
      while (stack.isNotEmpty && !identical(stack.last, existing)) {
        stack.last.pop();
      }
      if (home case final ScreenShell shell
          when shell.hosted.any((screen) => identical(screen, existing))) {
        shell.show(existing);
      }
      delegate.notifyListeners();
      _updateActive();
      return existing.future as Future<T?>;
    }

    if (top case final ScreenShell host when host.accept(page)) {
      page.parentHost = this;
      page.detach = () {
        delegate.notifyListeners();
        _updateActive();
      };
      page.removed = () {
        host.remove(page);
        Dispose.object(page);
      };
      page.onPush();
      delegate.notifyListeners();
      _updateActive();
      return page.future;
    }

    if (beside) FocusManager.instance.primaryFocus?.unfocus();
    page.parentHost = this;
    page.detach = () {
      FocusManager.instance.primaryFocus?.unfocus();
      stack.removeWhere((p) => identical(p, page));
      delegate.notifyListeners();
      _updateActive();
    };
    page.removed = () => Dispose.object(page);
    page.onPush();
    stack.add(page);

    delegate.notifyListeners();
    _updateActive();
    return page.future;
  }

  /// Find an already-mounted screen equal to [page], skipping popped
  /// entries. Scans shell-hosted children of [home] first, then the
  /// router stack bottom→top.
  Screen? _findMounted(Screen page) {
    if (home is ScreenShell) {
      for (final screen in (home as ScreenShell).hosted) {
        if (screen.popped) continue;
        if (identical(screen, page) || screen == page) return screen;
      }
    }
    for (final entry in stack) {
      if (entry.popped) continue;
      if (identical(entry, page) || entry == page) return entry;
    }
    return null;
  }

  /// Applies a parsed route: a configuration that resolves to [home]
  /// collapses the stack, anything else is pushed.
  Future<void> setNewRoutePath(Screen? configuration) {
    // A route that resolves to the home screen collapses the stack rather
    // than pushing: the parser mints a fresh instance for `/`, so an
    // identity/== check alone would stack a second home on every launch.
    if (configuration == null ||
        configuration == home ||
        configuration.runtimeType == home.runtimeType) {
      popAll();
      return SynchronousFuture(null);
    }
    return push(configuration);
  }
}

/// Routes system back, and Esc no [ScreenStack] takes, to the screen the
/// router's [ScreenStackState.backTop] names, the one a predictive back goes
/// to: asks its [Screen.handleBack], then pops it where its [Screen.canPop]
/// holds. Where it names none, back goes to the [Screen.handleBack] of the
/// bottom screen of [XRouter.pages]. Back that none of them takes returns
/// false, and goes to the OS.
class XRouterBack extends RootBackButtonDispatcher {
  /// Binds the router whose stack answers back.
  XRouterBack({required this.router});

  /// The router this dispatcher pops.
  final XRouter router;

  @override
  Future<bool> didPopRoute() async {
    final screens = router._screens.currentState;
    if (screens == null) return false;
    final page = screens.backTop;
    if (page == null) return screens.widget.home.handleBack();
    if (page.handleBack()) return true;
    // Not super.didPopRoute(): it calls the Router's callback, which calls
    // this again.
    if (!page.canPop) return false;
    page.pop();
    return true;
  }
}

/// Adapts an [XRouter] to Flutter's [Router].
class XRouterDelegate extends RouterDelegate<Screen> with Emitter {
  /// Binds the router this delegate renders.
  XRouterDelegate({required this.router});

  /// The router this delegate renders.
  final XRouter router;

  @override
  Widget build(BuildContext context) => router.build(context);

  @override
  Future<bool> popRoute() => router.backDispatcher.didPopRoute();

  @override
  Future<void> setNewRoutePath(Screen? configuration) async =>
      router.setNewRoutePath(configuration);

  /// Re-renders the router's [XRouter.pages]; public, for the router and its
  /// subclasses to call.
  @override
  void notifyListeners() => super.notifyListeners();

  @override
  Screen? get currentConfiguration => router.currentConfiguration;
}

/// Mixin for screens that can host other screens (e.g. a tab host showing
/// a detail screen alongside the tab bar).
///
/// When a screen is pushed, the router asks the current top screen's shell
/// whether to [accept] it. If accepted, the screen is managed by the shell
/// instead of the router's main stack.
mixin ScreenShell {
  /// Whether this shell wants to own [screen]. Return `true` to intercept
  /// the push — the screen will not go onto the router stack.
  bool accept(Screen screen) => false;

  /// Called after a hosted screen's exit animation completes.
  void remove(Screen screen) {}

  /// The screens this shell shows. The router flattens these into the
  /// [ScreenStack] alongside the main stack.
  Iterable<Screen> get pages => const [];

  /// Every screen this shell hosts, shown or hidden. A hosted screen that
  /// [pages] leaves out is hidden: it stays mounted offstage with its
  /// State, unpainted, out of hit testing and focus, its tickers muted.
  Iterable<Screen> get hosted => pages;

  /// Shows [screen], which this shell hosts, when a push equals it. The
  /// router re-reads [pages] afterwards.
  void show(Screen screen) {}

  /// Tells the router hosting this shell that [pages], [place] or
  /// [isBeside] changed outside a push or a pop, as when a tab host
  /// switches tabs.
  void pagesChanged() {
    if (this case Screen(parentHost: final ScreenShell router)) {
      router.pagesChanged();
    }
  }

  /// Wraps [slot], where hosted [screen] draws, to lay it out within this
  /// shell, such as in a pane. The wrapper is a child of the
  /// [ScreenStack]'s [Stack], so it may be a [Positioned]. The screen keeps
  /// the window's [MediaQuery].
  Widget place(BuildContext context, Screen screen, Widget slot) => slot;

  /// Whether [screen] sits beside this shell instead of covering it. The
  /// router asks before [accept] on a push, and for each hosted screen as
  /// it renders.
  ///
  /// A beside screen moves no focus as it comes and goes, except that focus
  /// inside one that leaves goes to this shell. Tab and Shift+Tab cross
  /// between this shell's controls and the screen's. The screen takes no
  /// edge-swipe or predictive-back drag, and back reaches this shell's
  /// [Screen.handleBack] unless [ScreenStackState.nestedTop] names a screen,
  /// as one a [ScreenStack] inside the screen shows above its home.
  bool isBeside(Screen screen) => false;
}

/// Mixin for screens that support deep-linking via a URL.
mixin Deeplink<T> on Screen<T> {
  /// The URL that would bring this screen back.
  String get restoreUrl;
}

/// A [RouteInformationParser] that converts URIs into [Screen]s
/// using a [UriParser], and restores URLs from [Deeplink] screens.
class XRouteParser extends RouteInformationParser<Object> {
  /// Binds the pattern set and the optional rewrite applied before it.
  XRouteParser({required this.parser, this.normalize});

  /// Matches a URI against the app's route patterns.
  final UriParser<Screen, dynamic> parser;

  /// Rewrites an incoming URI before it reaches [parser] — for instance to
  /// strip a host or a locale prefix.
  final Uri Function(Uri)? normalize;

  /// The screen [uri] names, or `null` when nothing matches.
  Screen? parse(Uri? uri) {
    if (uri == null) return null;
    if (normalize != null) uri = normalize!(uri);
    return parser.parse(uri, null);
  }

  @override
  Future<Object> parseRouteInformation(
    RouteInformation routeInformation,
  ) async {
    return parse(routeInformation.uri) as Object;
  }

  @override
  RouteInformation? restoreRouteInformation(Object configuration) {
    return (configuration is Deeplink ? configuration.restoreUrl : null)
        ?.pipe(Uri.tryParse)
        ?.pipe((uri) => RouteInformation(uri: uri));
  }
}

/// The root widget for a ux app.
///
/// Resolves a [XRouter] from the [Store] and sets up theming,
/// localization, scroll behavior, and back-button dispatching —
/// without pulling in Flutter's [Navigator] or [MaterialApp].
class XApp extends StatelessWidget {
  /// Binds the router to render and the app-wide theming and localization
  /// it renders under.
  const XApp({
    super.key,
    required this.router,
    this.title = '',
    this.theme,
    this.debugShowCheckedModeBanner = true,
    this.localizationsDelegates,
    this.supportedLocales = const [Locale('en')],
    this.scrollBehavior,
    this.overlayKey,
  });

  /// The router whose screens fill the app.
  final XRouter router;

  /// Name the OS shows for the app's window or task.
  final String title;

  /// Theme the whole tree resolves against; a default [ThemeData] when
  /// omitted.
  final ThemeData? theme;

  /// Whether the debug ribbon is drawn over the app.
  final bool debugShowCheckedModeBanner;

  /// App-supplied localizations, ahead of the Material and widget defaults.
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;

  /// Locales the app ships; the first is the one it runs in.
  final Iterable<Locale> supportedLocales;

  /// Scroll behaviour for the whole tree; Material's when omitted.
  final ScrollBehavior? scrollBehavior;

  /// Key on the root overlay, for hosts that insert their own entries.
  final GlobalKey<OverlayState>? overlayKey;

  @override
  Widget build(BuildContext context) {
    final data = theme ?? ThemeData();

    return Title(
      title: title,
      color: data.primaryColor,
      child: MediaQuery.fromView(
        view: View.of(context),
        child: Localizations(
          locale: supportedLocales.first,
          delegates: [
            ...?localizationsDelegates,
            DefaultMaterialLocalizations.delegate,
            DefaultWidgetsLocalizations.delegate,
          ],
          child: AnimatedTheme(
            data: data,
            child: ScrollConfiguration(
              behavior: scrollBehavior ?? const MaterialScrollBehavior(),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _dismissPastDisabled,
                child: Shortcuts(
                  shortcuts: WidgetsApp.defaultShortcuts,
                  child: Actions(
                    dispatcher: const _DismissPastDisabledDispatcher(),
                    actions: {
                      ...WidgetsApp.defaultActions,
                      _DismissPastDisabledIntent: _DismissPastDisabledAction(),
                    },
                    child: DefaultTextEditingShortcuts(
                      child: _AppRouter(
                        router: router,
                        child: Overlay(
                          key: overlayKey,
                          initialEntries: [OverlayEntry(builder: _buildRouter)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The [Router] over the nearest [_AppRouter]'s router, keyed by that
  /// router: another router gets a [Router] and screens of its own, and where
  /// the root overlay is built anew, as when the widgets above it change shape
  /// between platforms, the [Router] and its screens move there with their
  /// State.
  static Widget _buildRouter(BuildContext context) {
    final router = context
        .dependOnInheritedWidgetOfExactType<_AppRouter>()!
        .router;
    return _InspectorScope(
      key: GlobalObjectKey(router),
      child: Router(
        routeInformationParser: router.routeParser,
        routeInformationProvider: router.routeInformationProvider,
        routerDelegate: router.delegate,
        backButtonDispatcher: router.backDispatcher,
      ),
    );
  }
}

/// The router of the [XApp] above, for the [Router] in its root overlay's
/// entry to read: the overlay keeps the entry it was first built with.
class _AppRouter extends InheritedWidget {
  const _AppRouter({required this.router, required super.child});

  final XRouter router;

  @override
  bool updateShouldNotify(_AppRouter oldWidget) =>
      !identical(router, oldWidget.router);
}

/// Hands a key bound to [DismissIntent] that the action nearest the focus is
/// disabled for, such as a [Scaffold]'s with no drawer open, to the nearest
/// action around it that is enabled for it. [Shortcuts] stops at the nearest
/// action, enabled or not.
KeyEventResult _dismissPastDisabled(FocusNode node, KeyEvent event) {
  final focus = FocusManager.instance.primaryFocus?.context;
  final dismisses = WidgetsApp.defaultShortcuts.entries.any(
    (entry) =>
        entry.value is DismissIntent &&
        entry.key.accepts(event, HardwareKeyboard.instance),
  );
  if (focus == null || !dismisses) return KeyEventResult.ignored;
  return switch (_dismissNearestEnabled(focus)) {
    (final action, final invoked) => action.toKeyEventResult(
      _DismissPastDisabledIntent(action),
      invoked,
    ),
    null => KeyEventResult.ignored,
  };
}

/// Invokes the action [_nearestEnabled] finds, and returns it with what it
/// returned.
(Action<Intent>, Object?)? _dismissNearestEnabled(
  BuildContext context, {
  BuildContext? above,
}) => switch (_nearestEnabled(context, above: above)) {
  (final action, final dispatcher) => (
    action,
    dispatcher.invokeAction(
      action,
      _DismissPastDisabledIntent(action),
      context,
    ),
  ),
  null => null,
};

/// The action bound to [DismissIntent] nearest [context], or, where [above] is
/// given, nearest around it, that is enabled for a [_DismissPastDisabledIntent]
/// in [context], with the dispatcher of the [Actions] that binds it; null
/// where no such action is.
(Action<Intent>, ActionDispatcher)? _nearestEnabled(
  BuildContext context, {
  BuildContext? above,
}) {
  (Action<Intent>, ActionDispatcher)? found;
  (above ?? context).visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is! Actions) return true;
    final action = widget.actions[DismissIntent];
    if (action == null ||
        !_isEnabled(action, _DismissPastDisabledIntent(action), context)) {
      return true;
    }
    found = (action, widget.dispatcher ?? const ActionDispatcher());
    return false;
  });
  return found;
}

bool _isEnabled(Action<Intent> action, Intent intent, BuildContext context) =>
    action is ContextAction<Intent>
    ? action.isEnabled(intent, context)
    : action.isEnabled(intent);

/// The intent [XApp] invokes [DismissIntent] actions with. [Actions] looks an
/// action up by its intent's runtime type, so where an action hands this on
/// with [Actions.invoke], as a focused [EditableText]'s does, or looks up its
/// override with it, as an [Action.overridable] does, it reaches
/// [_DismissPastDisabledAction] rather than stopping at the nearest
/// [DismissIntent] action, enabled or not.
class _DismissPastDisabledIntent extends DismissIntent {
  const _DismissPastDisabledIntent(this.action);

  /// The action this intent is invoked on.
  final Action<Intent> action;
}

/// Invokes the [DismissIntent] action nearest the context it comes from that
/// is enabled for a [_DismissPastDisabledIntent]. Found as the override of an
/// [Action.overridable], it invokes the nearest such action around the
/// overridable, and where none is, it is enabled as the overridable's default
/// action is, and invokes that.
///
/// Handles [Intent] rather than [DismissIntent], as [callingAction] holds the
/// default action of the overridable, which may handle any intent, such as a
/// [DoNothingAction].
class _DismissPastDisabledAction extends ContextAction<Intent> {
  @override
  bool isEnabled(Intent intent, [BuildContext? context]) {
    final overridable = _overridable(intent, context);
    return overridable == null ||
        _isEnabled(callingAction!, intent, context!) ||
        _nearestEnabled(context, above: overridable) != null;
  }

  @override
  Object? invoke(Intent intent, [BuildContext? context]) {
    final overridden = callingAction;
    final overridable = _overridable(intent, context);
    return switch (_dismissNearestEnabled(context!, above: overridable)) {
      (_, final invoked) => invoked,
      null when overridable != null =>
        const ActionDispatcher()
            .invokeActionIfEnabled(overridden!, intent, context)
            .$2,
      null => null,
    };
  }

  /// The [Actions] around [context] binding the [Action.overridable] this is
  /// invoked as the override of, where [callingAction] is set: the one whose
  /// [DismissIntent] action [intent] is for. An intent handed on through a
  /// dispatcher other than [XApp]'s stays for the action handing it on, which
  /// is not around the context it is handed on from.
  BuildContext? _overridable(Intent intent, BuildContext? context) {
    if (callingAction == null) return null;
    final action = (intent as _DismissPastDisabledIntent).action;
    BuildContext? actions;
    context!.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Actions &&
          identical(widget.actions[DismissIntent], action)) {
        actions = element;
      }
      return actions == null;
    });
    return actions;
  }
}

/// Invokes an action with a [_DismissPastDisabledIntent] for that action in
/// place of a [DismissIntent], or of a [_DismissPastDisabledIntent] for
/// another. Any other subclass of [DismissIntent] is bound to actions of its
/// own type, and reaches them as it is.
class _DismissPastDisabledDispatcher extends ActionDispatcher {
  const _DismissPastDisabledDispatcher();

  @override
  Object? invokeAction(
    Action<Intent> action,
    Intent intent, [
    BuildContext? context,
  ]) => super.invokeAction(action, _pastDisabled(action, intent), context);

  @override
  (bool, Object?) invokeActionIfEnabled(
    Action<Intent> action,
    Intent intent, [
    BuildContext? context,
  ]) => super.invokeActionIfEnabled(
    action,
    _pastDisabled(action, intent),
    context,
  );

  Intent _pastDisabled(Action<Intent> action, Intent intent) =>
      intent is _DismissPastDisabledIntent ||
          intent.runtimeType == DismissIntent
      ? _DismissPastDisabledIntent(action)
      : intent;
}

/// Inserts a [WidgetInspector] when DevTools' "select widget" mode is active.
///
/// [XApp] has no [WidgetsApp]/[MaterialApp], so nothing in the tree responds to
/// the inspector override flag — on-device tap-to-select (and the constraint
/// readout it drives) silently does nothing. This mirrors what `WidgetsApp`
/// does: listen to [WidgetsBinding.debugShowWidgetInspectorOverrideNotifier]
/// and wrap the content in a [WidgetInspector] only while select mode is on
/// (the inspector's [GestureDetector] joins every gesture arena, so it must
/// not stay mounted when idle).
///
/// The child is kept under a stable [GlobalKey] so that inserting/removing the
/// inspector *reparents* the subtree rather than rebuilding it, and the
/// [Router] and its screens keep their State.
///
/// Debug-only and inert until toggled. The on-device exit/move/tap-behavior
/// buttons are left unbuilt (null) — Material's defaults rely on a private
/// button widget we can't reuse — so select mode is toggled from DevTools.
class _InspectorScope extends StatefulWidget {
  const _InspectorScope({super.key, required this.child});

  final Widget child;

  @override
  State<_InspectorScope> createState() => _InspectorScopeState();
}

class _InspectorScopeState extends State<_InspectorScope> {
  final GlobalKey _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;
    return ValueListenableBuilder<bool>(
      valueListenable:
          WidgetsBinding.instance.debugShowWidgetInspectorOverrideNotifier,
      child: KeyedSubtree(key: _childKey, child: widget.child),
      builder: (context, selecting, child) {
        if (!selecting) return child!;
        return WidgetInspector(
          exitWidgetSelectionButtonBuilder: null,
          moveExitWidgetSelectionButtonBuilder: null,
          tapBehaviorButtonBuilder: null,
          child: child!,
        );
      },
    );
  }
}
