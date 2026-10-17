import 'dart:io';

import 'diff.dart';
import 'props.dart';
import 'wire.dart';

/// What the classes read beside a disagreement.
class ClassData {
  /// The [characters] of Unicode 17.0.0 and macOS 26.4, the oracle commit's
  /// [tlds] in lowercase with its Unicode labels, and the [newTlds] the Dart
  /// detector's list adds to them.
  const ClassData(this.characters, this.tlds, this.newTlds);

  /// The character classes.
  final CharacterClasses characters;

  /// The oracle commit's TLDs.
  final Set<String> tlds;

  /// The TLDs newer than the oracle commit's.
  final Set<String> newTlds;
}

/// The entries of tool/url_data's newest TLD list that [oracleTlds] lacks,
/// in lowercase.
Set<String> newTlds(String uxRoot, Set<String> oracleTlds) {
  final lists =
      Directory('$uxRoot/tool/url_data')
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'tlds-\d+\.txt$').hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final line in lists.last.readAsLinesSync())
      if (line.isNotEmpty &&
          !line.startsWith('#') &&
          !oracleTlds.contains(line.toLowerCase()))
        line.toLowerCase(),
  };
}

/// The classes a disagreement between darwin and the Dart detector falls in:
/// one per ledger entry, one per open question, the Unicode class and the
/// new-TLD class, in the order a disagreement is tried against them.
List<DisagreementClass> disagreementClasses(ClassData data) {
  final c = data.characters;
  bool unspaced(int cp) =>
      (cp >= 0x0E00 && cp <= 0x0EFF) ||
      (cp >= 0x1000 && cp <= 0x109F) ||
      (cp >= 0x1100 && cp <= 0x11FF) ||
      (cp >= 0x1780 && cp <= 0x17FF) ||
      (cp >= 0x2E80 && cp <= 0x9FFF) ||
      (cp >= 0xA960 && cp <= 0xA97F) ||
      (cp >= 0xAC00 && cp <= 0xD7FF) ||
      (cp >= 0xF900 && cp <= 0xFAFF) ||
      (cp >= 0xFF66 && cp <= 0xFFDC) ||
      (cp >= 0x20000 && cp <= 0x3FFFF);
  final differences = c.differences;
  bool letterMarkDigit(int cp) =>
      c.letters.contains(cp) || c.marks.contains(cp) || c.digits.contains(cp);

  bool b1(Disagreement d) {
    if (!d.darwin || !_bare(d)) return false;
    final labels = _host(d).split('.');
    return labels.length >= 2 &&
        labels.last.isNotEmpty &&
        labels.last.runes.every(unspaced) &&
        labels[labels.length - 2].isNotEmpty &&
        labels[labels.length - 2].codeUnits.every((u) => u < 0x80);
  }

  bool b5Link(String text, Link link) {
    if (link.kind != 'web' || !link.url.startsWith('http://')) return false;
    if (_scheme.hasMatch(text.substring(link.start, link.end))) return false;
    final first = _hostOf(text.substring(link.start, link.end))
        .split('.')
        .first;
    return first.runes.any(
      (cp) => cp >= 0x80 && !unspaced(cp) && c.letters.contains(cp),
    );
  }

  bool b5(Disagreement d) {
    final text = d.text;
    if (!d.darwin) {
      return b5Link(text, d.link) &&
          d.reading.links.every(
            (l) =>
                l.link.end <= d.link.start ||
                l.link.start >= d.link.end ||
                (l.link.start >= d.link.start && l.link.end <= d.link.end),
          );
    }
    return d.dart.any(
      (l) =>
          b5Link(text, l) &&
          !d.reading.links.any((r) => r.link == l) &&
          l.start <= d.link.start &&
          d.link.end <= l.end,
    );
  }

  return [
    DisagreementClass('a1: marks before a ? or : after a host', (d) {
      if (classOf(d.link, d.text) != LinkClass.webScheme) return false;
      if (d.darwin) return _a1Host.hasMatch(d.slice);
      return !_hasPath(d.slice) &&
          _a1Tail.hasMatch(d.text.substring(d.link.end));
    }),
    DisagreementClass('a2: a Cf run inside a word starts no bare host', (d) {
      if (!d.darwin || !_bare(d)) return false;
      var i = d.link.start;
      var skipped = 0;
      while (i > 0 && c.format.contains(_before(d.text, i))) {
        i -= _width(_before(d.text, i));
        skipped++;
      }
      if (skipped == 0 || i == 0) return false;
      final cp = _before(d.text, i);
      return letterMarkDigit(cp) && !unspaced(cp);
    }),
    DisagreementClass('b1: an ASCII label under an unspaced-script TLD', b1),
    DisagreementClass('b2: the continuation cut over every kind', (d) {
      if (!d.darwin) return false;
      return [...d.reading.links.map((l) => l.link), ...d.dart].any((p) {
        if (p.end > d.link.start) return false;
        final between = d.text.substring(p.end, d.link.start);
        return between.contains('）') && !between.contains(RegExp(r'\s'));
      });
    }),
    DisagreementClass("b3: an unopened ')'", (d) {
      if (classOf(d.link, d.text) != LinkClass.webScheme) return false;
      final slice = d.slice;
      if (d.darwin) {
        final m = RegExp(r"\)[.,;!'()?:]*$").firstMatch(slice);
        if (m == null) return false;
        final head = slice.substring(0, m.start);
        return _count(head, ')') + 1 > _count(head, '(');
      }
      final rest = d.text.substring(d.link.end);
      return rest.startsWith(')') &&
          _count(slice, '(') <= _count(slice, ')') &&
          RegExp(r"^\)[.,;!'()?:]*(\s|$)").hasMatch(rest);
    }),
    DisagreementClass('b4: EMAIL_ADDRESS', (d) {
      bool emailAddress(Link l) =>
          l.kind == 'email' &&
          _emailAddress.hasMatch(d.text.substring(l.start, l.end));
      if (!d.darwin) return emailAddress(d.link);
      return d.dart.any(
        (e) =>
            emailAddress(e) &&
            !d.reading.links.any((r) => r.link == e) &&
            e.start < d.link.end &&
            d.link.start < e.end,
      );
    }),
    DisagreementClass(
      'b5: an IDN first label outside the unspaced scripts',
      b5,
    ),
    DisagreementClass("b6: NSDataDetector's host cut inside a label", (d) {
      if (!d.darwin || !_bare(d)) return false;
      final stage = d.reading.links.firstWhere((l) => l.link == d.link).stage;
      if (stage != Stage.nsdd || d.link.end + 1 >= d.text.length) return false;
      final next = _at(d.text, d.link.end + 1);
      return d.text[d.link.end] == '-' &&
          (c.letters.contains(next) || c.digits.contains(next));
    }),
    DisagreementClass('b7: a TLD glued to a word character', (d) {
      if (!d.darwin || !_bare(d) || _hasPath(d.slice)) return false;
      if (d.slice.contains(':') || d.link.end >= d.text.length) return false;
      final next = _at(d.text, d.link.end);
      return c.word.contains(next) && !unspaced(next);
    }),
    DisagreementClass('b8: a webcal:// with no host', (d) {
      return d.darwin &&
          d.slice.toLowerCase().startsWith('webcal://') &&
          d.reading.reading.raw.any(
            (r) => r.start == d.link.start && r.end == d.link.start + 8,
          );
    }),
    DisagreementClass("b9: unspaced letters after a scheme link's host", (d) {
      if (classOf(d.link, d.text) != LinkClass.webScheme) return false;
      if (d.darwin) {
        final host = _schemeHost(d.slice);
        for (var i = 1; i < host.length; i++) {
          final before = host.codeUnitAt(i - 1);
          if (unspaced(host.codeUnitAt(i)) &&
              before != 0x2E &&
              !unspaced(before)) {
            return true;
          }
        }
        return false;
      }
      return !_hasPath(d.slice) &&
          d.link.end < d.text.length &&
          d.text[d.link.end - 1] != '.' &&
          !unspaced(_before(d.text, d.link.end)) &&
          unspaced(_at(d.text, d.link.end));
    }),
    DisagreementClass('b11: a trailing curly quote or ellipsis', (d) {
      if (d.darwin) {
        return RegExp('[”’…]+\$').hasMatch(d.slice) || d.slice.startsWith('“');
      }
      return d.link.end < d.text.length && '”’…'.contains(d.text[d.link.end]);
    }),
    DisagreementClass('b10: a trailing non-ASCII symbol run', (d) {
      if (d.darwin) {
        if (d.link.end >= d.text.length) return false;
        if (c.word.contains(_at(d.text, d.link.end))) return false;
        final runes = d.slice.runes.toList();
        for (
          var i = runes.length - 1;
          i >= 0 && !c.word.contains(runes[i]);
          i--
        ) {
          if (runes[i] >= 0x80) return true;
        }
        return false;
      }
      if (d.link.end >= d.text.length) return false;
      final next = _at(d.text, d.link.end);
      return next >= 0x80 && !c.word.contains(next);
    }),
    DisagreementClass('b12: a fullwidth-digit port', (d) {
      final around = d.text.substring(
        d.link.start,
        d.link.end + 3 > d.text.length ? d.text.length : d.link.end + 3,
      );
      return RegExp(':[０-９]').hasMatch(around);
    }),
    DisagreementClass('b13: a written tel: URI', (d) {
      if (!d.darwin) {
        return d.link.kind == 'web' &&
            d.slice.toLowerCase().startsWith('tel:') &&
            !d.reading.links.any((l) => l.link.start == d.link.start);
      }
      return d.link.kind == 'phone' &&
          d.dart.any(
            (t) =>
                t.start < d.link.start &&
                d.link.end <= t.end &&
                d.text
                    .substring(t.start, t.end)
                    .toLowerCase()
                    .startsWith('tel:'),
          );
    }),
    DisagreementClass('b14: a fifth number', (d) {
      return d.darwin &&
          _bare(d) &&
          _ipv4.hasMatch(_host(d)) &&
          d.link.end + 1 < d.text.length &&
          d.text[d.link.end] == '.' &&
          _isAsciiDigit(d.text.codeUnitAt(d.link.end + 1));
    }),
    DisagreementClass('b15: the glue letter is category L', (d) {
      if (d.link.kind != 'web' || d.link.end + 1 >= d.text.length) return false;
      if (d.text[d.link.end] != '.') return false;
      final next = _at(d.text, d.link.end + 1);
      if (unspaced(next)) return false;
      final dart = c.letters.contains(next);
      final darwin = c.macLetters.contains(next);
      return d.darwin ? dart && !darwin : darwin && !dart;
    }),
    DisagreementClass("b16: an email's domain ends in a real TLD", (d) {
      if (!d.darwin || d.link.kind != 'email') return false;
      final domain = d.slice
          .substring(d.slice.lastIndexOf('@') + 1)
          .split('?')
          .first;
      if (_ipv4.hasMatch(domain)) return false;
      return !data.tlds.contains(domain.split('.').last.toLowerCase());
    }),
    DisagreementClass('b17: a Cf run after unspaced-script text', (d) {
      if (d.darwin || !_bare(d)) return false;
      if (d.reading.links.any((l) => l.link.start == d.link.start)) {
        return false;
      }
      var i = d.link.start;
      var skipped = 0;
      while (i > 0 && c.format.contains(_before(d.text, i))) {
        i -= _width(_before(d.text, i));
        skipped++;
      }
      return skipped > 0 && i > 0 && unspaced(_before(d.text, i));
    }),
    DisagreementClass("question 1: a host right before '://'", (d) {
      if (d.darwin) return _bare(d) && d.text.startsWith('://', d.link.end);
      return classOf(d.link, d.text) == LinkClass.webScheme &&
          d.reading.links.any(
            (l) =>
                l.link.start <= d.link.start &&
                d.link.start < l.link.end &&
                d.text.startsWith('://', l.link.end),
          );
    }),
    DisagreementClass('question 2: a leading-zero octet', (d) {
      return d.darwin && _bare(d) && _leadingZero.hasMatch(_host(d));
    }),
    DisagreementClass("question 3: a phone extension's URL", (d) {
      if (d.link.kind != 'phone') return false;
      final other = d.darwin ? d.dart : d.reading.links.map((l) => l.link);
      return other.any(
        (l) =>
            l.kind == 'phone' && l.start == d.link.start && l.end == d.link.end,
      );
    }),
    DisagreementClass("question 4: a scheme link's host characters", (d) {
      if (classOf(d.link, d.text) != LinkClass.webScheme) return false;
      if (d.darwin) return _q4Host.hasMatch(_authority(d.slice));
      return !_hasPath(d.slice) &&
          d.link.end < d.text.length &&
          "!\$&'()*+,;=~".contains(d.text[d.link.end]);
    }),
    DisagreementClass('question 6: a non-ASCII label beyond b5', (d) {
      return _bare(d) && _host(d).codeUnits.any((u) => u >= 0x80);
    }),
    DisagreementClass(
      'Unicode: a code point the tables and macOS 26.4 disagree on',
      (d) {
        final from = d.link.start >= 2 ? d.link.start - 2 : 0;
        final to = d.link.end + 2 > d.text.length
            ? d.text.length
            : d.link.end + 2;
        return d.text.substring(from, to).runes.any(differences.contains);
      },
    ),
    DisagreementClass('new TLDs: a TLD newer than the oracle\'s list', (d) {
      return _bare(d) &&
          data.newTlds.contains(_host(d).split('.').last.toLowerCase());
    }),
  ];
}

final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');
final _a1Host = RegExp(r"^[A-Za-z][A-Za-z0-9+.\-]*://[^/?#:]*?[.,;!']+[?:]");
final _a1Tail = RegExp(r"^[.,;!']+[?:]");
final _emailAddress = RegExp(
  r'^[a-zA-Z0-9+._%\-]{1,256}@[a-zA-Z0-9][a-zA-Z0-9\-]{0,64}(\.[a-zA-Z0-9][a-zA-Z0-9\-]{0,25})+$',
);
final _ipv4 = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');
final _leadingZero = RegExp(r'^(\d+\.){0,3}0\d');
final _q4Host = RegExp(r"[!$&'()*+,;=~]");

extension on Disagreement {
  String get text => reading.corpus.text;

  String get slice => text.substring(link.start, link.end);
}

/// Whether [d]'s link is a web link written with no scheme.
bool _bare(Disagreement d) => classOf(d.link, d.text) == LinkClass.web;

/// The host of [d]'s link, which has no scheme.
String _host(Disagreement d) => _hostOf(d.slice);

String _hostOf(String slice) {
  final end = slice.indexOf(RegExp('[:/?#]'));
  return end < 0 ? slice : slice.substring(0, end);
}

/// The authority of a scheme link's text: what follows its `://` and any
/// userinfo, up to its path, query, fragment or port.
String _authority(String slice) {
  final after = slice.substring(slice.indexOf('://') + 3);
  final end = after.indexOf(RegExp('[/?#]'));
  final authority = end < 0 ? after : after.substring(0, end);
  final at = authority.lastIndexOf('@');
  final host = at < 0 ? authority : authority.substring(at + 1);
  if (host.startsWith('[')) return '';
  final port = RegExp(r':\d*$').firstMatch(host);
  return port == null ? host : host.substring(0, port.start);
}

String _schemeHost(String slice) {
  final host = _authority(slice);
  final colon = host.indexOf(':');
  return colon < 0 ? host : host.substring(0, colon);
}

/// Whether a link's text has a path, query or fragment after its authority.
bool _hasPath(String slice) {
  final at = slice.indexOf('://');
  return slice.substring(at < 0 ? 0 : at + 3).contains(RegExp('[/?#]'));
}

int _count(String s, String c) => c.allMatches(s).length;

bool _isAsciiDigit(int u) => u >= 0x30 && u <= 0x39;

/// The code point that starts at [i] of [text].
int _at(String text, int i) {
  final high = text.codeUnitAt(i);
  if (high >= 0xD800 && high <= 0xDBFF && i + 1 < text.length) {
    final low = text.codeUnitAt(i + 1);
    if (low >= 0xDC00 && low <= 0xDFFF) {
      return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return high;
}

/// The code point that ends before [i] of [text].
int _before(String text, int i) {
  final low = text.codeUnitAt(i - 1);
  if (i >= 2 && low >= 0xDC00 && low <= 0xDFFF) {
    final high = text.codeUnitAt(i - 2);
    if (high >= 0xD800 && high <= 0xDBFF) {
      return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return low;
}

int _width(int cp) => cp > 0xFFFF ? 2 : 1;
