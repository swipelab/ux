/// The part of ux that is plain Dart and Flutter, and so runs everywhere, the
/// web included: [BendBox], bezier curves, reactive primitives ([Emitter],
/// [ValueEmitter]), navigation ([XApp], [XRouter], [Screen]) and modal sheets
/// ([Sheet]).
///
/// Each native component has a library of its own, such as
/// `package:ux/keyboard.dart` or `package:ux/camera.dart`.
library;

export 'src/app_info.dart';
export 'src/bend_box.dart';
export 'src/json_extension.dart';
export 'src/bezier.dart';
export 'src/view_padding.dart';
export 'src/auto_map.dart';
export 'src/functional.dart';

// Reactive primitives, lifecycle, DI, async tasks (formerly `stated`).
export 'src/core/core.dart';

// Reactive state base + builders.
export 'src/reactive/reactive.dart';
export 'src/reactive/reactive_builder.dart';
export 'src/reactive/future_reactive_builder.dart';

// Navigation (Screen, XApp, XRouter, ScreenStack, ScreenHero, …).
export 'src/navi/screen.dart';
export 'src/navi/screen_host.dart';
export 'src/navi/screen_stack.dart';
export 'src/navi/hero.dart';
export 'src/navi/sheet_screen.dart';
export 'src/navi/transitions.dart';
export 'src/navi/router.dart';

// Animations, layout, sheet, pane.
export 'src/anim/animated_color.dart';
export 'src/anim/animated_double.dart';
export 'src/anim/dock.dart';
export 'src/anim/measured.dart';
export 'src/anim/pane.dart';
export 'src/anim/sheet.dart';
