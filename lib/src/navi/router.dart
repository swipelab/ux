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
  XRouter({required this.home, this.routeParser}) {
    home.parentHost = this;
    _updateActive();
  }

  final Screen home;
  final RouteInformationParser<Object>? routeParser;
  late final stack = ListEmitter<Screen>()..disposeBy(this);
  late final delegate = XRouterDelegate(router: this);
  late final backDispatcher = XRouterBack(router: this);

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

  Screen? get currentConfiguration => stack.lastOrNull ?? home;

  Iterable<Screen> _expand(Screen page) sync* {
    yield page;
    if (page is ScreenShell) {
      for (final screen in (page as ScreenShell).pages) {
        if (!screen.popped) yield screen;
      }
    }
  }

  List<Screen> get pages => [
    ..._expand(home),
    for (final page in stack) ..._expand(page),
  ];

  late final _overlayEntry = OverlayEntry(builder: _buildContent);

  bool get canPop {
    if (stack.isNotEmpty) return true;
    if (home is ScreenShell) {
      for (final screen in (home as ScreenShell).pages) {
        if (!screen.popped) return true;
      }
    }
    return false;
  }

  void _updateSystemBack() {
    SystemNavigator.setFrameworkHandlesBack(canPop);
  }

  Widget _buildContent(BuildContext context) {
    // [pages] (not the [home]/[stack] fields) so subclasses can
    // override for gating — e.g. swap home to an auth screen.
    final p = pages;
    return MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: Material(
        child: NotificationListener<NavigationNotification>(
          onNotification: (_) => true, // absorb — router manages system back directly
          child: ScreenStack(
            home: p.first,
            stack: p.skip(1).toList(),
          ),
        ),
      ),
    );
  }

  Widget build(BuildContext context) {
    _overlayEntry.markNeedsBuild();
    return Overlay(initialEntries: [_overlayEntry]);
  }

  void popAll() {
    while (stack.isNotEmpty) {
      stack.last.pop();
    }
    if (home is ScreenShell) {
      for (final screen in (home as ScreenShell).pages.toList()) {
        screen.pop();
      }
    }
  }

  /// Push [page] onto the router.
  ///
  /// If an `==`-equal page is already mounted (shell-hosted by [home] or
  /// anywhere on [stack]), pops every stack entry above it and returns
  /// that existing page's future — the caller awaits until the mounted
  /// page is popped. No duplicate is created, no fresh instance is
  /// mounted. For identity-equal screens (no `==` override), this dedup
  /// path is unreachable; behavior matches the pre-dedup semantics.
  ///
  /// The type parameter `T` on the awaiter may differ from the mounted
  /// page's original `T`; the returned future is cast. Pushing an equal
  /// page of a different `T` is undefined.
  Future<T?> push<T>(Screen<T> page) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (home == page) {
      popAll();
      return SynchronousFuture(null);
    }

    final existing = _findMounted(page);
    if (existing != null) {
      while (stack.isNotEmpty && !identical(stack.last, existing)) {
        stack.last.pop();
      }
      delegate.notifyListeners();
      _updateActive();
      return existing.future as Future<T?>;
    }

    final top = stack.lastOrNull ?? home;
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
      for (final hosted in (home as ScreenShell).pages) {
        if (hosted.popped) continue;
        if (identical(hosted, page) || hosted == page) return hosted;
      }
    }
    for (final entry in stack) {
      if (entry.popped) continue;
      if (identical(entry, page) || entry == page) return entry;
    }
    return null;
  }

  Future<void> setNewRoutePath(Screen? configuration) {
    if (configuration == null || configuration == home) {
      popAll();
      return SynchronousFuture(null);
    }
    return push(configuration);
  }
}

class XRouterBack extends RootBackButtonDispatcher {
  XRouterBack({required this.router});

  final XRouter router;

  @override
  Future<bool> didPopRoute() async {
    for (final page in router.stack.reversed) {
      if (page.handleBack()) return true;
    }
    if (router.home.handleBack()) return true;
    final page = router.stack.lastOrNull;
    if (page != null) {
      page.pop();
      return true;
    }
    return super.didPopRoute();
  }
}

class XRouterDelegate extends RouterDelegate<Screen> with Emitter {
  XRouterDelegate({required this.router});

  final XRouter router;

  @override
  Widget build(BuildContext context) => router.build(context);

  @override
  Future<bool> popRoute() => router.backDispatcher.didPopRoute();

  @override
  Future<void> setNewRoutePath(Screen? configuration) async =>
      router.setNewRoutePath(configuration);

  @override
  void notifyListeners() {
    super.notifyListeners();
    router._updateSystemBack();
  }

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

  /// The screens currently hosted by this shell. The router flattens
  /// these into the [ScreenStack] alongside the main stack.
  Iterable<Screen> get pages => const [];
}

/// Mixin for screens that support deep-linking via a URL.
mixin Deeplink<T> on Screen<T> {
  String get restoreUrl;
}

/// A [RouteInformationParser] that converts URIs into [Screen]s
/// using a [UriParser], and restores URLs from [Deeplink] screens.
class XRouteParser extends RouteInformationParser<Object> {
  XRouteParser({required this.parser, this.normalize});

  final UriParser<Screen, dynamic> parser;
  final Uri Function(Uri)? normalize;

  Screen? parse(Uri? uri) {
    if (uri == null) return null;
    if (normalize != null) uri = normalize!(uri);
    return parser.parse(uri, null);
  }

  @override
  Future<Object> parseRouteInformation(RouteInformation routeInformation) async {
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

  final XRouter router;
  final String title;
  final ThemeData? theme;
  final bool debugShowCheckedModeBanner;
  final Iterable<LocalizationsDelegate<dynamic>>? localizationsDelegates;
  final Iterable<Locale> supportedLocales;
  final ScrollBehavior? scrollBehavior;
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
              child: Overlay(
                key: overlayKey,
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => Shortcuts(
                      shortcuts: WidgetsApp.defaultShortcuts,
                      child: Actions(
                        actions: WidgetsApp.defaultActions,
                        child: DefaultTextEditingShortcuts(
                          child: Router(
                            routeInformationParser: router.routeParser,
                            routerDelegate: router.delegate,
                            backButtonDispatcher: router.backDispatcher,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
