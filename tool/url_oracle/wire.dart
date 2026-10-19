import 'dart:convert';
import 'dart:typed_data';

/// One link of a reading: a UTF-16 span, its kind (`web`, `email` or
/// `phone`) and its URL.
class Link {
  /// A link of [kind] over [start, end) of a text, opening [url].
  const Link(this.start, this.end, this.kind, this.url);

  /// The link a JSON array `[start, end, kind, url]` holds.
  factory Link.fromJson(List<Object?> json) => Link(
    json[0]! as int,
    json[1]! as int,
    json[2]! as String,
    json[3]! as String,
  );

  /// Inclusive start, in UTF-16 code units.
  final int start;

  /// Exclusive end, in UTF-16 code units.
  final int end;

  /// `web`, `email` or `phone`.
  final String kind;

  /// The URL the link opens.
  final String url;

  /// This link as a JSON array `[start, end, kind, url]`.
  List<Object> toJson() => [start, end, kind, url];

  @override
  bool operator ==(Object other) =>
      other is Link &&
      start == other.start &&
      end == other.end &&
      kind == other.kind &&
      url == other.url;

  @override
  int get hashCode => Object.hash(start, end, kind, url);

  @override
  String toString() => '[$start,$end) $kind ${printable(url)}';
}

/// One raw NSDataDetector result: a link with its URL or a phone number with
/// its phone string.
class RawResult {
  /// A result over [start, end), a phone number where [phone] holds, whose
  /// URL or phone string is [value].
  const RawResult(
    this.start,
    this.end, {
    required this.phone,
    required this.value,
  });

  /// Inclusive start, in UTF-16 code units.
  final int start;

  /// Exclusive end, in UTF-16 code units.
  final int end;

  /// Whether NSDataDetector typed it a phone number rather than a link.
  final bool phone;

  /// The link's absolute URL or the phone number's string.
  final String value;

  /// This result as a JSON array `[start, end, "l" or "p", value]`.
  List<Object> toJson() => [start, end, phone ? 'p' : 'l', value];

  @override
  String toString() =>
      '[$start,$end) ${phone ? 'phone' : 'link'} ${printable(value)}';
}

/// One of url_detect.mm's candidates before its sort.
class Candidate {
  /// [link], which NSDataDetector gave where [nsdd] holds and the second pass
  /// otherwise.
  const Candidate(this.link, {required this.nsdd});

  /// The candidate's span, kind and URL.
  final Link link;

  /// Whether NSDataDetector gave it.
  final bool nsdd;
}

/// One probe line: ux_match_url's buffer and raw NSDataDetector's results.
class ProbeReading {
  /// The reading of a text whose native buffer is [buffer], whose raw
  /// NSDataDetector results are [raw] and whose url_detect.mm candidates are
  /// [candidates] in a probe-stages reading.
  const ProbeReading(this.buffer, this.raw, [this.candidates]);

  /// The probe's JSON line `{"b": buffer, "r": raw}`, with `"c":
  /// candidates` in a probe-stages reading.
  factory ProbeReading.fromLine(String line) {
    final json = jsonDecode(line) as Map<String, Object?>;
    final candidates = json['c'] as List<Object?>?;
    return ProbeReading(
      base64Decode(json['b']! as String),
      [
        for (final r in (json['r']! as List<Object?>).cast<List<Object?>>())
          RawResult(
            r[0]! as int,
            r[1]! as int,
            phone: r[2] == 'p',
            value: fromUtf16Base64(r[3]! as String),
          ),
      ],
      candidates == null
          ? null
          : [
              for (final c in candidates.cast<List<Object?>>())
                Candidate(
                  Link(
                    c[0]! as int,
                    c[1]! as int,
                    _kinds[c[2]! as int],
                    utf8.decode(base64Decode(c[3]! as String)),
                  ),
                  nsdd: c[4] == 'n',
                ),
            ],
    );
  }

  /// ux_match_url's buffer, empty where it returns none.
  final Uint8List buffer;

  /// Raw NSDataDetector's results.
  final List<RawResult> raw;

  /// url_detect.mm's candidates before its sort, in a probe-stages reading.
  final List<Candidate>? candidates;

  /// The links [buffer] holds.
  List<Link> get native => decodeBuffer(buffer);
}

const _kinds = ['web', 'email', 'phone'];

/// The links of ux_match_url's wire layout: u32 count, then count entries of
/// i32 start, i32 end, u32 kind, u32 url_len and url_len bytes of UTF-8.
List<Link> decodeBuffer(Uint8List buffer) {
  if (buffer.length < 4) return const [];
  final view = ByteData.sublistView(buffer);
  final links = <Link>[];
  var p = 4;
  for (var i = 0, count = view.getUint32(0, Endian.little); i < count; i++) {
    final urlLength = view.getUint32(p + 12, Endian.little);
    links.add(
      Link(
        view.getInt32(p, Endian.little),
        view.getInt32(p + 4, Endian.little),
        _kinds[view.getUint32(p + 8, Endian.little)],
        utf8.decode(Uint8List.sublistView(buffer, p + 16, p + 16 + urlLength)),
      ),
    );
    p += 16 + urlLength;
  }
  return links;
}

/// [text]'s UTF-16LE code units in base64, which keeps a lone surrogate.
String toUtf16Base64(String text) {
  final units = Uint16List.fromList(text.codeUnits);
  return base64Encode(units.buffer.asUint8List());
}

/// The text whose UTF-16LE code units [encoded] holds in base64.
String fromUtf16Base64(String encoded) {
  final bytes = base64Decode(encoded);
  return String.fromCharCodes(Uint16List.sublistView(bytes));
}

/// [value] as JSON with every code unit outside printable ASCII escaped, so a
/// lone surrogate survives a UTF-8 file.
String asciiJson(Object? value) {
  final json = jsonEncode(value);
  final out = StringBuffer();
  for (final unit in json.codeUnits) {
    if (unit >= 0x20 && unit < 0x7F) {
      out.writeCharCode(unit);
    } else {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    }
  }
  return out.toString();
}

/// [text] with each code unit outside printable ASCII as a `\u` escape.
String printable(String text) {
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    if (unit >= 0x20 && unit < 0x7F) {
      out.writeCharCode(unit);
    } else {
      out.write('\\u${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    }
  }
  return out.toString();
}

/// [literal]'s value as C++ reads its `\u`, `\U` and character escapes.
String unescapeCpp(String literal) {
  final out = StringBuffer();
  for (var i = 0; i < literal.length; i++) {
    final c = literal[i];
    if (c != r'\') {
      out.write(c);
      continue;
    }
    final kind = literal[++i];
    if (kind == 'u' || kind == 'U') {
      final digits = kind == 'u' ? 4 : 8;
      out.writeCharCode(
        int.parse(literal.substring(i + 1, i + 1 + digits), radix: 16),
      );
      i += digits;
    } else {
      out.write(const {'n': '\n', 't': '\t'}[kind] ?? kind);
    }
  }
  return out.toString();
}
