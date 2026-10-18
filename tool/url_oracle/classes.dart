import 'dart:io';

import 'diff.dart';
import 'props.dart';
import 'wire.dart';

/// What the classes read beside a disagreement.
class ClassData {
  /// The [characters] of Unicode 17.0.0 and macOS 26.4, the oracle commit's
  /// [tlds] in lowercase with its Unicode labels, the [newTlds] the Dart
  /// detector's list adds to them, and the TLDs NSDataDetector links a bare
  /// host on, [nsddBare], and a host whose first label is www on,
  /// [nsddWww].
  const ClassData(
    this.characters,
    this.tlds,
    this.newTlds, {
    required this.nsddBare,
    required this.nsddWww,
  });

  /// The character classes.
  final CharacterClasses characters;

  /// The oracle commit's TLDs.
  final Set<String> tlds;

  /// The TLDs newer than the oracle commit's.
  final Set<String> newTlds;

  /// The TLDs NSDataDetector links `see bücher.<tld> x` on, in lowercase.
  final Set<String> nsddBare;

  /// The TLDs NSDataDetector links `see www.bücher.<tld> x` on, in
  /// lowercase.
  final Set<String> nsddWww;
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
  final differences = c.differences;
  bool letterMarkDigit(int cp) =>
      c.letters.contains(cp) || c.marks.contains(cp) || c.digits.contains(cp);

  /// Whether [d]'s link and a link only the other side holds are related
  /// as [related] states, darwin's first.
  bool paired(Disagreement d, bool Function(Link darwin, Link dart) related) =>
      d.darwin
      ? _dartOnly(d).any((l) => related(d.link, l))
      : _darwinOnly(d).any((l) => related(l, d.link));

  /// Whether [tld] is on the oracle's list as step 3 matches a bare host's
  /// TLD.
  bool listed(String tld) =>
      data.tlds.contains(tld) ||
      const {'com', 'edu', 'gov', 'net', 'org'}.contains(tld.toLowerCase());

  /// Whether [label] holds letters, marks and digits with inner '-' or '_'.
  bool label(String label) =>
      label.isNotEmpty &&
      !'-_'.contains(label[0]) &&
      !'-_'.contains(label[label.length - 1]) &&
      label.runes.every(
        (cp) => letterMarkDigit(cp) || cp == 0x2D || cp == 0x5F,
      );

  /// Whether [label] holds a letter outside ASCII and the unspaced scripts.
  bool spaced(String label) => label.runes.any(
    (cp) => cp >= 0x80 && !_unspaced(cp) && c.letters.contains(cp),
  );

  /// Whether NSDataDetector's model takes [label], whose letters are ASCII
  /// or of the unspaced scripts, in a host whose first label is www where
  /// [www] holds.
  bool nsddTakes(String label, {required bool www}) {
    final letters = label.runes.where(
      (cp) => cp >= 0x80 && c.letters.contains(cp),
    );
    if (letters.every(_hangul)) return true;
    return www && letters.every(_wwwScript);
  }

  /// Whether [labels] end in an unspaced-script TLD with an ASCII label
  /// before it.
  bool b1Shape(List<String> labels) =>
      labels.length >= 2 &&
      labels.last.isNotEmpty &&
      labels.last.runes.every(_unspaced) &&
      labels[labels.length - 2].isNotEmpty &&
      labels[labels.length - 2].codeUnits.every((u) => u < 0x80);

  /// The labels of [link]'s host where it is a web link of [text] with no
  /// scheme.
  List<String>? bareLabels(String text, Link link) {
    if (link.kind != 'web' || !link.url.startsWith('http://')) return null;
    final slice = text.substring(link.start, link.end);
    if (_scheme.hasMatch(slice)) return null;
    return _hostOf(slice).split('.');
  }

  bool b5Link(String text, Link link) {
    final labels = bareLabels(text, link);
    if (labels == null || labels.length < 2) return false;
    if (!spaced(labels.first) || !listed(labels.last) || b1Shape(labels)) {
      return false;
    }
    return labels
        .take(labels.length - 1)
        .every((l) => label(l) && !l.runes.any(_unspaced));
  }

  bool q6Link(String text, Link link) {
    final labels = bareLabels(text, link);
    if (labels == null || labels.length < 2 || b5Link(text, link)) {
      return false;
    }
    final tld = labels.last;
    if (!labels.any((l) => l.codeUnits.any((u) => u >= 0x80))) return false;
    if (!listed(tld) || b1Shape(labels)) return false;
    final www = labels.first.toLowerCase() == 'www';
    var cause = !(www ? data.nsddWww : data.nsddBare).contains(
      tld.toLowerCase(),
    );
    for (final l in labels.take(labels.length - 1)) {
      if (!label(l)) return false;
      if (spaced(l)) {
        cause = true;
      } else if (!nsddTakes(l, www: www)) {
        return false;
      }
    }
    return cause;
  }

  /// Whether [d] is a Dart link [isLink] holds, where every darwin link
  /// over it lies inside it, or a darwin link inside such a Dart link.
  bool dartLinkOver(Disagreement d, bool Function(String, Link) isLink) {
    bool holds(Link l) =>
        isLink(d.text, l) &&
        _darwinLinks(d).every(
          (r) =>
              r.end <= l.start ||
              r.start >= l.end ||
              (r.start >= l.start && r.end <= l.end),
        );
    if (!d.darwin) return holds(d.link);
    return _dartOnly(d)
        .any((l) => holds(l) && l.start <= d.link.start && d.link.end <= l.end);
  }

  /// Where b10 ends [link] of [text]: before the first character of its
  /// trailing run of non-word characters that is neither ASCII nor Cf,
  /// where a non-word character follows the link.
  int? b10Cut(String text, Link link) {
    if (link.end >= text.length || c.word.contains(_at(text, link.end))) {
      return null;
    }
    int? cut;
    for (var i = link.end; i > link.start;) {
      final cp = _before(text, i);
      if (c.word.contains(cp)) break;
      i -= _width(cp);
      if (cp >= 0x80 && !c.format.contains(cp)) cut = i;
    }
    return cut;
  }

  /// Where question 4's host grammar ends the host of [link], a scheme
  /// link of [text]: at the first character that is no letter, mark,
  /// digit, '-', '_', '.' or '%XX', skipping Cf characters, before the
  /// host's port, path, query or fragment.
  int? q4Cut(String text, Link link) {
    final host = _schemeHostStart(text, link);
    if (host == null) return null;
    for (var i = host; i < link.end;) {
      final cp = _at(text, i);
      if ('/?#:'.codeUnits.contains(cp)) return null;
      if (cp == 0x25 && _percent.matchAsPrefix(text, i) != null) {
        i += 3;
        continue;
      }
      if (!letterMarkDigit(cp) &&
          !c.format.contains(cp) &&
          !'-_.'.codeUnits.contains(cp)) {
        return i;
      }
      i += _width(cp);
    }
    return null;
  }

  /// The b11 span of [link] of [text]: without a trailing run of ” ’ …
  /// and, in a bare host, without an opening “.
  (int, int)? b11Span(String text, Link link) {
    var start = link.start;
    if (link.kind == 'web' &&
        bareLabels(text, link) != null &&
        text[start] == '“') {
      start++;
    }
    var end = link.end;
    while (end > start && '”’…'.contains(text[end - 1])) {
      end--;
    }
    return start == link.start && end == link.end ? null : (start, end);
  }

  /// Whether [cut] is [darwin] ended at [end], its URL ending where its text
  /// does.
  bool cutAt(String text, Link darwin, Link cut, int end) =>
      cut.start == darwin.start &&
      cut.end == end &&
      cut.kind == darwin.kind &&
      darwin.url.startsWith(cut.url) &&
      cut.url.endsWith(_sanitize(text.substring(cut.start, cut.end)));

  return [
    DisagreementClass('a1: marks before a ? or : after a host', (d) {
      return paired(d, (darwin, dart) {
        if (classOf(darwin, d.text) != LinkClass.webScheme) return false;
        final m = _a1Host.firstMatch(
          d.text.substring(darwin.start, darwin.end),
        );
        return m != null &&
            cutAt(d.text, darwin, dart, darwin.start + m[1]!.length);
      });
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
      return letterMarkDigit(cp) && !_unspaced(cp);
    }),
    DisagreementClass('b1: an ASCII label under an unspaced-script TLD', (d) {
      return d.darwin && _bare(d) && b1Shape(_host(d).split('.'));
    }),
    DisagreementClass('b2: the continuation cut over every kind', (d) {
      if (!d.darwin) return false;
      return [..._darwinLinks(d), ...d.dart].any(
        (p) =>
            p.kind == 'web' &&
            p.end <= d.link.start &&
            _continues(d.text.substring(p.end, d.link.start)),
      );
    }),
    DisagreementClass("b3: an unopened ')'", (d) {
      return paired(d, (darwin, dart) {
        if (classOf(darwin, d.text) != LinkClass.webScheme) return false;
        final slice = d.text.substring(darwin.start, darwin.end);
        final m = RegExp(r"\)[.,;!'()?:]*$").firstMatch(slice);
        if (m == null) return false;
        final head = slice.substring(0, m.start);
        return _count(head, ')') + 1 > _count(head, '(') &&
            cutAt(d.text, darwin, dart, darwin.start + m.start);
      });
    }),
    DisagreementClass('b4: EMAIL_ADDRESS', (d) {
      final matches = [
        for (final m in _emailAddress.allMatches(d.text))
          if (_emailTld(m[0]!, data.tlds))
            Link(
              m.start,
              m.end,
              'email',
              'mailto:${m[1]!.replaceAll('%', '%25')}@${m[2]!}',
            ),
      ];
      bool wins(Link m, Link other) =>
          other.start > m.start ||
          (other.start == m.start && other.end < m.end);
      bool overlaps(Link a, Link b) => a.start < b.end && b.start < a.end;
      if (!d.darwin) {
        return matches.contains(d.link) &&
            _darwinLinks(d)
                .where((r) => overlaps(r, d.link))
                .every((r) => wins(d.link, r));
      }
      return _dartOnly(d).any(
        (l) => matches.contains(l) && overlaps(l, d.link) && wins(l, d.link),
      );
    }),
    DisagreementClass(
      'b5: an IDN first label outside the unspaced scripts',
      (d) => dartLinkOver(d, b5Link),
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
      return c.word.contains(next) && !_unspaced(next);
    }),
    DisagreementClass('b8: a webcal:// with no host', (d) {
      return d.darwin &&
          d.slice.toLowerCase().startsWith('webcal://') &&
          d.reading.reading.raw.any(
            (r) => r.start == d.link.start && r.end == d.link.start + 8,
          );
    }),
    DisagreementClass("b9: unspaced letters after a scheme link's host", (d) {
      return paired(d, (darwin, dart) {
        if (classOf(darwin, d.text) != LinkClass.webScheme) return false;
        final host = _schemeHostStart(d.text, darwin);
        if (host == null) return false;
        for (var i = host; i < darwin.end;) {
          final cp = _at(d.text, i);
          if ('/?#:'.codeUnits.contains(cp)) return false;
          if (i > host &&
              _unspaced(cp) &&
              d.text[i - 1] != '.' &&
              !_unspaced(_before(d.text, i))) {
            return cutAt(d.text, darwin, dart, i);
          }
          i += _width(cp);
        }
        return false;
      });
    }),
    DisagreementClass('b11: a trailing curly quote or ellipsis', (d) {
      return paired(d, (darwin, dart) {
        final span = b11Span(d.text, darwin);
        if (span == null) return false;
        final (start, end) = span;
        final bare = bareLabels(d.text, darwin) != null;
        return dart.start == start &&
            dart.end == end &&
            dart.kind == darwin.kind &&
            dart.url ==
                '${bare ? 'http://' : ''}${_sanitize(d.text.substring(start, end))}';
      });
    }),
    DisagreementClass('b10: a trailing non-ASCII symbol run', (d) {
      return paired(d, (darwin, dart) {
        final cut = b10Cut(d.text, darwin);
        return cut != null && cutAt(d.text, darwin, dart, cut);
      });
    }),
    DisagreementClass('b12: a fullwidth-digit port', (d) {
      return paired(d, (darwin, dart) {
        if (darwin.start != dart.start || darwin.kind != dart.kind) {
          return false;
        }
        if (darwin.end == dart.end) {
          return dart.url != darwin.url &&
              _foldWidth(darwin.url) == dart.url &&
              RegExp(':[０-９]').hasMatch(darwin.url);
        }
        if (dart.end < darwin.end) return false;
        final port = d.text.substring(darwin.end, dart.end);
        return RegExp(r'^:[０-９]+$').hasMatch(port) &&
            dart.url == '${darwin.url}${_foldWidth(port)}';
      });
    }),
    DisagreementClass('b13: a written tel: URI', (d) {
      return !d.darwin &&
          d.link.kind == 'web' &&
          d.slice.toLowerCase().startsWith('tel:') &&
          d.link.url == _sanitize(d.slice) &&
          !d.reading.links.any((l) => l.link.start == d.link.start);
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
      if (_unspaced(next)) return false;
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
      return skipped > 0 && i > 0 && _unspaced(_before(d.text, i));
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
      return paired(d, (darwin, dart) {
        if (darwin.kind != 'phone' ||
            dart.kind != 'phone' ||
            darwin.start != dart.start ||
            darwin.end != dart.end) {
          return false;
        }
        return d.reading.reading.raw.any((r) {
          if (!r.phone || r.start != darwin.start || r.end != darwin.end) {
            return false;
          }
          final extension = RegExp(r';(\d+)$').firstMatch(r.value);
          return extension != null &&
              darwin.url == '${dart.url}${extension[1]}';
        });
      });
    }),
    DisagreementClass("question 4: a scheme link's host characters", (d) {
      bool cut(Link darwin, Link dart) {
        if (classOf(darwin, d.text) != LinkClass.webScheme) return false;
        final end = q4Cut(d.text, darwin);
        return end != null && cutAt(d.text, darwin, dart, end);
      }

      bool emptyHost(Link darwin) =>
          classOf(darwin, d.text) == LinkClass.webScheme &&
          q4Cut(d.text, darwin) == _schemeHostStart(d.text, darwin) &&
          !d.dart.any((l) => l.start == darwin.start);
      bool after(Link darwin, Link dart) {
        if (classOf(darwin, d.text) != LinkClass.webScheme) return false;
        final end = q4Cut(d.text, darwin);
        if (end == null || dart.start < end || dart.end > darwin.end) {
          return false;
        }
        return bareLabels(d.text, dart) != null &&
            (emptyHost(darwin) || _dartOnly(d).any((l) => cut(darwin, l)));
      }

      if (d.darwin && emptyHost(d.link)) return true;
      return paired(d, cut) ||
          (!d.darwin && _darwinOnly(d).any((l) => after(l, d.link)));
    }),
    DisagreementClass(
      'question 6: a non-ASCII label beyond b5',
      (d) => dartLinkOver(d, q6Link),
    ),
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

/// The unspaced scripts: Han, kana, Bopomofo, Hangul, Thai, Lao, Khmer and
/// Myanmar, with CJK symbols and punctuation.
bool _unspaced(int cp) =>
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

/// Hangul, a label of which NSDataDetector's model takes in any host.
bool _hangul(int cp) =>
    (cp >= 0x1100 && cp <= 0x11FF) ||
    (cp >= 0x3130 && cp <= 0x318F) ||
    (cp >= 0xA960 && cp <= 0xA97F) ||
    (cp >= 0xAC00 && cp <= 0xD7FF) ||
    (cp >= 0xFFA0 && cp <= 0xFFDC);

/// Han, kana and Thai, a label of which NSDataDetector's model takes only in
/// a host whose first label is www.
bool _wwwScript(int cp) =>
    (cp >= 0x0E00 && cp <= 0x0E7F) ||
    (cp >= 0x2E80 && cp <= 0x2FDF) ||
    (cp >= 0x3005 && cp <= 0x3007) ||
    (cp >= 0x3021 && cp <= 0x3029) ||
    (cp >= 0x3038 && cp <= 0x303C) ||
    (cp >= 0x3040 && cp <= 0x30FF) ||
    (cp >= 0x31F0 && cp <= 0x31FF) ||
    (cp >= 0x3400 && cp <= 0x4DBF) ||
    (cp >= 0x4E00 && cp <= 0x9FFF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFF66 && cp <= 0xFF9F) ||
    (cp >= 0x20000 && cp <= 0x3FFFF);

/// CJK punctuation, which ends a link (R8).
bool _cjkPunctuation(int cp) =>
    (cp >= 0x3001 && cp <= 0x3003) ||
    (cp >= 0x3008 && cp <= 0x3011) ||
    (cp >= 0x3014 && cp <= 0x301F) ||
    (cp >= 0xFE10 && cp <= 0xFE19) ||
    (cp >= 0xFE30 && cp <= 0xFE6B) ||
    (cp >= 0xFF01 && cp <= 0xFF0F) ||
    (cp >= 0xFF1A && cp <= 0xFF20) ||
    (cp >= 0xFF3B && cp <= 0xFF40) ||
    (cp >= 0xFF5B && cp <= 0xFF65);

/// Whether [between], the text from a web link's end to a match, continues
/// that link's path past a fullwidth parenthesis: trim marks, then '（',
/// then path text through '）', with no whitespace and no other CJK
/// punctuation.
bool _continues(String between) {
  final open = between.indexOf('（');
  if (open < 0 || !RegExp(r"^[.,;!']*$").hasMatch(between.substring(0, open))) {
    return false;
  }
  final rest = between.substring(open);
  return rest.contains('）') &&
      !rest.contains(RegExp(r'\s')) &&
      rest.runes.every(
        (cp) => cp == 0xFF08 || cp == 0xFF09 || !_cjkPunctuation(cp),
      );
}

final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');
final _percent = RegExp('%[0-9A-Fa-f]{2}');
final _a1Host = RegExp(r"^([A-Za-z][A-Za-z0-9+.\-]*://[^/?#:]*?)[.,;!']+[?:]");
final _emailAddress = RegExp(
  r'([a-zA-Z0-9+._%\-]{1,256})@([a-zA-Z0-9][a-zA-Z0-9\-]{0,64}(?:\.[a-zA-Z0-9][a-zA-Z0-9\-]{0,25})+)',
);
final _ipv4 = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');
final _leadingZero = RegExp(r'^(\d+\.){0,3}0\d');

/// Whether [address]'s domain is an IPv4 address or ends in one of [tlds],
/// in any case (b16).
bool _emailTld(String address, Set<String> tlds) {
  final domain = address.substring(address.lastIndexOf('@') + 1);
  return _ipv4.hasMatch(domain) ||
      tlds.contains(domain.split('.').last.toLowerCase());
}

/// [url] without the characters XUrl.match's URL leaves out: tab, LF, CR,
/// NBSP, ZWSP, ZWNJ, ZWJ, U+2060–U+2065, U+206A–U+206F and U+FEFF.
String _sanitize(String url) => String.fromCharCodes(
  url.codeUnits.where(
    (c) =>
        !(c == 0x09 ||
            c == 0x0A ||
            c == 0x0D ||
            c == 0xA0 ||
            (c >= 0x200B && c <= 0x200D) ||
            (c >= 0x2060 && c <= 0x2065) ||
            (c >= 0x206A && c <= 0x206F) ||
            c == 0xFEFF),
  ),
);

/// [s] with each fullwidth digit as its ASCII digit.
String _foldWidth(String s) => String.fromCharCodes(
  s.codeUnits.map((u) => u >= 0xFF10 && u <= 0xFF19 ? u - 0xFF10 + 0x30 : u),
);

extension on Disagreement {
  String get text => reading.corpus.text;

  String get slice => text.substring(link.start, link.end);
}

List<Link> _darwinLinks(Disagreement d) => [
  for (final l in d.reading.links) l.link,
];

Iterable<Link> _darwinOnly(Disagreement d) =>
    _darwinLinks(d).where((l) => !d.dart.contains(l));

Iterable<Link> _dartOnly(Disagreement d) =>
    d.dart.where((l) => !d.reading.links.any((r) => r.link == l));

/// Whether [d]'s link is a web link written with no scheme.
bool _bare(Disagreement d) => classOf(d.link, d.text) == LinkClass.web;

/// The host of [d]'s link, which has no scheme.
String _host(Disagreement d) => _hostOf(d.slice);

String _hostOf(String slice) {
  final end = slice.indexOf(RegExp('[:/?#]'));
  return end < 0 ? slice : slice.substring(0, end);
}

/// Where the host of [link], a scheme link of [text], starts: after its
/// `://` and any userinfo, outside an IP literal.
int? _schemeHostStart(String text, Link link) {
  final slice = text.substring(link.start, link.end);
  final scheme = _scheme.firstMatch(slice);
  if (scheme == null) return null;
  final after = slice.substring(scheme.end);
  final end = after.indexOf(RegExp('[/?#]'));
  final authority = end < 0 ? after : after.substring(0, end);
  final host = authority.lastIndexOf('@') + 1;
  if (authority.startsWith('[', host)) return null;
  return link.start + scheme.end + host;
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
