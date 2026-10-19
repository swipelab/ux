// p4's locality over probe-stages' recorded readings: the texts darwin reads
// otherwise in a segment's window alone than in the whole text.
import 'rules.dart';
import 'selfcheck.dart';
import 'wire.dart';

/// probe-stages readings by text, recording each text a read lacks.
class Recorded {
  /// Readings that start with [readings].
  Recorded(this.readings);

  /// probe-stages readings by text.
  final Map<String, ProbeReading> readings;

  /// The texts asked for and lacked since [nonLocal]'s last round.
  final Set<String> _missing = {};

  ProbeReading? _of(String text) {
    final r = readings[text];
    if (r == null) _missing.add(text);
    return r;
  }

  /// The segment windows of [text] p4 reads, each with its offset in the
  /// bounded text and its segment, and the bounded text they are cut from;
  /// null where a reading they need is missing.
  ({String bounded, Map<String, (int, int, int)> windows})? _windows(
    String text,
  ) {
    final whole = _of(text);
    if (whole == null) return null;
    final bounded = text.substring(0, boundOf(text, whole.raw));
    final r = _of(bounded);
    if (r == null) return null;
    final windows = <String, (int, int, int)>{};
    for (final (start, end) in Segments(bounded, r.raw).spans) {
      final from = start == 0 ? 0 : start - 1;
      final to = end + 3 > bounded.length ? bounded.length : end + 3;
      final window = bounded.substring(from, to);
      if (window != bounded) windows[window] = (from, start, end);
    }
    return (bounded: bounded, windows: windows);
  }

  /// The texts of [texts], in order, darwin reads otherwise in a segment's
  /// window alone than in the text, reading every window reading it lacks
  /// through [read].
  Future<List<String>> nonLocal(
    List<String> texts,
    Future<List<ProbeReading>> Function(List<String> texts) read,
  ) async {
    final found = <String>{};
    var pending = texts;
    while (pending.isNotEmpty) {
      _missing.clear();
      final next = <String>[];
      for (final t in pending) {
        final local = _local(t);
        if (local == null) {
          next.add(t);
        } else if (!local) {
          found.add(t);
        }
      }
      if (_missing.isNotEmpty) {
        final lacked = _missing.toList();
        final readings = await read(lacked);
        for (var i = 0; i < lacked.length; i++) {
          this.readings[lacked[i]] = readings[i];
        }
      }
      pending = next;
    }
    return [
      for (final t in texts)
        if (found.contains(t)) t,
    ];
  }

  /// Whether darwin reads each segment window of [text] as it reads that
  /// segment in the text; null where a reading is missing.
  bool? _local(String text) {
    final cut = _windows(text);
    if (cut == null) return null;
    final whole = readings[cut.bounded]!;
    for (final MapEntry(key: window, value: (from, start, end))
        in cut.windows.entries) {
      final own = _of(window);
      if (own == null) return null;
      bool inside(int i) => start <= i && i < end;
      final mine = [
        for (final c in own.candidates!)
          if (inside(c.link.start + from)) _shifted(c.link, from),
      ];
      final theirs = [
        for (final c in whole.candidates!)
          if (inside(c.link.start)) c.link,
      ];
      if (!sameLinks(mine, theirs)) return false;
    }
    return true;
  }
}

Link _shifted(Link l, int by) => Link(l.start + by, l.end + by, l.kind, l.url);
