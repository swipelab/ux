import 'dart:convert';
import 'dart:io';

import 'corpus.dart';
import 'harness.dart';
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

  /// Whether every link's class is one of [classes].
  bool holdsOnly(Set<LinkClass> classes) =>
      links.every((l) => classes.contains(l.linkClass));

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

/// A link one side holds and the other does not.
class Disagreement {
  /// [link] of [reading]'s text, which darwin holds where [darwin] is true
  /// and the Dart detector otherwise.
  const Disagreement(this.reading, this.link, {required this.darwin});

  /// The darwin reading of the text.
  final DarwinReading reading;

  /// The link only one side holds.
  final Link link;

  /// Whether darwin holds [link].
  final bool darwin;

  @override
  String toString() =>
      '${printable(reading.corpus.text)}: ${darwin ? 'darwin' : 'Dart'} only $link';
}

/// A named class of disagreements: a ledger entry, an open question or a
/// computed class, and the predicate that decides membership.
class DisagreementClass {
  /// The class [name], holding the disagreements [holds] accepts.
  const DisagreementClass(this.name, this.holds);

  /// The class's name in the report.
  final String name;

  /// Whether a disagreement falls in this class.
  final bool Function(Disagreement d) holds;
}

/// Each link [darwin] and [dart] do not share, text by text.
List<Disagreement> disagreements(
  List<DarwinReading> darwin,
  List<List<Link>> dart,
) => [
  for (var i = 0; i < darwin.length; i++) ...[
    for (final l in darwin[i].links)
      if (!dart[i].contains(l.link))
        Disagreement(darwin[i], l.link, darwin: true),
    for (final l in dart[i])
      if (!darwin[i].links.any((d) => d.link == l))
        Disagreement(darwin[i], l, darwin: false),
  ],
];
