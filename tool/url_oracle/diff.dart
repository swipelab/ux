import 'dart:convert';
import 'dart:io';

import 'corpus.dart';
import 'harness.dart';
import 'rules.dart';
import 'wire.dart';

/// Where a darwin link comes from: raw NSDataDetector's link, the second pass
/// or the any-scheme pass.
enum Stage {
  /// A native link that starts where raw NSDataDetector's does and ends
  /// within it.
  nsdd,

  /// A native link raw NSDataDetector has no link for.
  second,

  /// A link outside the first 64 of the native buffer.
  anyScheme,
}

/// What a link is: an email, a phone, a web link written with `scheme://`,
/// one written with a scheme and no `//`, or a host with no scheme.
enum LinkClass {
  /// A web link whose text starts with a scheme and `://`.
  webScheme('web-scheme'),

  /// A web link whose text starts with a scheme and no `//`.
  opaque('opaque'),

  /// A web link whose URL is `http://` and its text.
  web('web'),

  /// An email.
  email('email'),

  /// A phone number.
  phone('phone');

  const LinkClass(this.label);

  /// The name `--kinds` takes.
  final String label;
}

/// One darwin link with its stage and class.
class DarwinLink {
  /// [link] of [text], from [stage].
  DarwinLink(this.link, this.stage, String text)
    : linkClass = classOf(link, text);

  /// The link as XUrl.match gives it.
  final Link link;

  /// The pass that produced it.
  final Stage stage;

  /// What it is.
  final LinkClass linkClass;

  /// This link as `[start, end, kind, url, stage, class]`.
  List<Object> toJson() => [...link.toJson(), stage.name, linkClass.label];
}

final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');

/// The class of [link] in [text].
LinkClass classOf(Link link, String text) {
  if (link.kind == 'email') return LinkClass.email;
  if (link.kind == 'phone') return LinkClass.phone;
  if (_scheme.hasMatch(text.substring(link.start, link.end))) {
    return LinkClass.webScheme;
  }
  return link.url.startsWith('http://') ? LinkClass.web : LinkClass.opaque;
}

/// The stage of [link], given the native buffer and raw results of its text.
Stage stageOf(Link link, ProbeReading reading) {
  final capped = reading.native.take(64);
  if (!capped.any((n) => n.start == link.start && n.end == link.end)) {
    return Stage.anyScheme;
  }
  final raw = reading.raw.any(
    (r) => r.start == link.start && link.end <= r.end,
  );
  return raw ? Stage.nsdd : Stage.second;
}

/// The darwin reading of one corpus text.
class DarwinReading {
  /// [text]'s XUrl.match [links], tagged from its probe [reading].
  DarwinReading(this.corpus, List<Link> links, this.reading)
    : links = [
        for (final l in links) DarwinLink(l, stageOf(l, reading), corpus.text),
      ];

  /// The text and its family.
  final CorpusText corpus;

  /// XUrl.match's links, each with its stage and class.
  final List<DarwinLink> links;

  /// The probe's native buffer and raw results.
  final ProbeReading reading;

  /// Whether every link's class, and every class of [predicted]'s links, is
  /// one of [classes].
  bool holdsOnly(Set<LinkClass> classes, List<Link> predicted) =>
      links.every((l) => classes.contains(l.linkClass)) &&
      predicted.every((l) => classes.contains(classOf(l, corpus.text)));

  /// This reading as darwin.json holds it.
  Map<String, Object> toJson() => {
    'family': corpus.family,
    'text': corpus.text,
    'links': [for (final l in links) l.toJson()],
    'native': [for (final l in reading.native) l.toJson()],
    'raw': [for (final r in reading.raw) r.toJson()],
  };
}

/// darwin.json: a header of the run, then one reading per line.
String encodeDarwin(Map<String, Object> header, List<DarwinReading> readings) {
  final out = StringBuffer()..writeln(asciiJson(header));
  for (final r in readings) {
    out.writeln(asciiJson(r.toJson()));
  }
  return out.toString();
}

/// The counts the diff reports over [readings].
List<String> counts(List<DarwinReading> readings) {
  final families = <String, int>{};
  final classes = <String, int>{};
  final stages = <String, int>{};
  var linked = 0;
  final overCap = <String, int>{};
  for (final r in readings) {
    families[r.corpus.family] = (families[r.corpus.family] ?? 0) + 1;
    if (r.links.isNotEmpty) linked++;
    for (final l in r.links) {
      classes[l.linkClass.label] = (classes[l.linkClass.label] ?? 0) + 1;
      stages[l.stage.name] = (stages[l.stage.name] ?? 0) + 1;
    }
    if (r.links.length > 64) {
      for (final stage in {for (final l in r.links) l.stage.name}) {
        overCap[stage] = (overCap[stage] ?? 0) + 1;
      }
    }
  }
  String line(String name, Map<String, int> map) =>
      '$name: ${(map.keys.toList()..sort()).map((k) => '$k ${map[k]}').join(', ')}';
  return [
    'texts: ${readings.length}, $linked with a link',
    line('families', families),
    line('links by class', classes),
    line('links by stage', stages),
    line('texts of more than 64 links, by a stage among them', overCap),
  ];
}

/// The texts among [readings] whose native buffer or raw results under
/// another locale differ from [readings]', with what each locale reads.
List<String> localeDifferences(
  List<DarwinReading> readings,
  Map<String, List<ProbeReading>> byLocale,
) {
  final out = <String>[];
  for (var i = 0; i < readings.length; i++) {
    final base = readings[i].reading;
    for (final MapEntry(key: locale, value: other) in byLocale.entries) {
      final r = other[i];
      if (jsonEncode(base.buffer) != jsonEncode(r.buffer) ||
          '${base.raw}' != '${r.raw}') {
        out.add(
          '${printable(readings[i].corpus.text)}: $locale native ${r.native} raw ${r.raw}',
        );
      }
    }
  }
  return out;
}

/// The library whose `detectLinks(String text)` is the Dart detector.
const detectorLibrary = 'package:ux/src/url/detect.dart';

/// The Dart detector's links of each of [texts], from a script under [dir]
/// that [uxRoot]'s package config resolves.
Future<List<List<Link>>> dartReading(
  String uxRoot,
  Directory dir,
  List<String> texts,
) async {
  final script = File('${dir.path}/dart_reading.dart')
    ..writeAsStringSync('''
import 'dart:io';

import '$detectorLibrary';
import '$uxRoot/tool/url_oracle/wire.dart';

void main(List<String> args) {
  final out = StringBuffer();
  for (final line in File(args[0]).readAsLinesSync()) {
    final links = detectLinks(fromUtf16Base64(line));
    out.writeln(asciiJson([for (final m in links) [m.start, m.end, m.kind.name, m.url]]));
  }
  File(args[1]).writeAsStringSync(out.toString());
}
''');
  final input = File('${dir.path}/dart_texts')
    ..writeAsStringSync('${texts.map(toUtf16Base64).join('\n')}\n');
  final output = File('${dir.path}/dart_links');
  await run('dart', [
    '--packages=$uxRoot/.dart_tool/package_config.json',
    script.path,
    input.path,
    output.path,
  ]);
  return [
    for (final line in output.readAsLinesSync())
      [
        for (final l in jsonDecode(line) as List<Object?>)
          Link.fromJson(l! as List<Object?>),
      ],
  ];
}

/// A link the prediction and darwin's reading do not share, with the edit
/// whose class it falls in.
typedef Classified = ({Link link, bool darwin, String edit});

/// Each link [darwin] and [full], the whole ledger's prediction, do not
/// share, with whether darwin holds it and its class: the first edit, in the
/// ledger's order, from which every longer prefix of the ledger predicts the
/// link as the whole ledger does. [prefixes] holds the predictions of the
/// ledger's first one, two, … edits, the last of them [full].
List<Classified> attribute(
  List<Link> darwin,
  List<Link> full,
  List<List<Link>> prefixes,
) {
  final out = <Classified>[];
  void classify(Link link, {required bool inDarwin}) {
    final inFull = full.contains(link);
    var k = prefixes.length - 1;
    while (k > 0 && prefixes[k - 1].contains(link) == inFull) {
      k--;
    }
    out.add((link: link, darwin: inDarwin, edit: ledger[k].$1));
  }

  for (final l in darwin) {
    if (!full.contains(l)) classify(l, inDarwin: true);
  }
  for (final l in full) {
    if (!darwin.contains(l)) classify(l, inDarwin: false);
  }
  return out;
}

/// A link the Dart reading and the prediction do not share, or a Dart link
/// over a span the prediction leaves unpredicted.
class Departure {
  /// [link] of [text], which the Dart reading holds where [dart] is true and
  /// the prediction otherwise.
  const Departure(this.text, this.link, {required this.dart});

  /// The text.
  final String text;

  /// The link only one side holds.
  final Link link;

  /// Whether the Dart reading holds [link].
  final bool dart;

  @override
  String toString() =>
      '${printable(text)}: ${dart ? 'Dart' : 'prediction'} only $link';
}

/// The departures of [dart], the Dart reading of [text], from [prediction].
List<Departure> departures(
  String text,
  List<Link> dart,
  Prediction prediction,
) {
  bool over(Link l) =>
      prediction.unpredicted.any((u) => l.start < u.$2 && u.$1 < l.end);
  return [
    for (final l in prediction.links)
      if (!dart.contains(l)) Departure(text, l, dart: false),
    for (final l in dart)
      if (!prediction.links.contains(l) || over(l))
        Departure(text, l, dart: true),
  ];
}
