import 'package:flutter/foundation.dart';
import 'package:ux/ux.dart';

/// Coordinates "which chat bubble is currently being shown by a gallery and
/// should hide its image." Maintains a stack of [HideSlot]s so overlapping
/// gallery screens (A's close-anim still running while B is pushed) don't
/// clobber each other: A's release pops only A's slot, leaving B's bubble
/// hidden until B itself releases.
///
/// Within one screen, swiping the pager calls [update] on the same slot so
/// the hidden bubble follows the central item without churning the stack.
class HiddenMediaController with Emitter {
  HiddenMediaController._();

  /// The one controller of the app.
  static final HiddenMediaController instance = HiddenMediaController._();

  final List<HideSlot> _stack = <HideSlot>[];

  /// Currently-hidden source id (= top of stack), or null when nothing is
  /// hidden.
  Object? get hidden => _stack.isEmpty ? null : _stack.last.id;

  /// Whether [id] is the hidden source.
  bool isHidden(Object? id) =>
      id != null && _stack.isNotEmpty && _stack.last.id == id;

  /// Push a new hide-slot. The owner must keep the returned [HideSlot]
  /// and pass it back to [update] / [release].
  HideSlot acquire(Object id) {
    final slot = HideSlot._(id);
    final before = hidden;
    _stack.add(slot);
    if (hidden != before) notifyListeners();
    return slot;
  }

  /// Change [slot]'s id (e.g. on pager swipe). No-op if the slot was
  /// already released.
  void update(HideSlot slot, Object id) {
    if (!_stack.contains(slot)) return;
    final before = hidden;
    slot._id = id;
    if (hidden != before) notifyListeners();
  }

  /// Pop [slot] from the stack. No-op if already released. When [slot] is
  /// the top, the previous slot's id (if any) becomes hidden again.
  void release(HideSlot slot) {
    final before = hidden;
    if (!_stack.remove(slot)) return;
    if (hidden != before) notifyListeners();
  }

  /// Drops every slot without notifying.
  @visibleForTesting
  void clearForTest() {
    _stack.clear();
  }
}

/// Opaque handle returned by [HiddenMediaController.acquire]. Identity-based.
class HideSlot {
  HideSlot._(this._id);
  Object _id;
  /// The source this slot hides.
  Object get id => _id;
}
