/// One detected span inside a source string.
class UrlMatch {
  /// Creates a span with UTF-16 [start]/[end] offsets and a canonical [url].
  const UrlMatch({
    required this.start,
    required this.end,
    required this.url,
    required this.kind,
  });

  /// Inclusive UTF-16 code-unit offset.
  final int start;

  /// Exclusive UTF-16 code-unit offset.
  final int end;

  /// Canonical URL: `www.x.com` → `http://www.x.com`, phone →
  /// `tel:<digits>`, email → `mailto:<addr>`. Where the link's text
  /// holds a bidi control that the native detector's URL leaves out, it is
  /// that URL's scheme and then the text, or the text alone where it starts
  /// with that scheme, such as `tel:+1 ` and a right-to-left mark before
  /// `555 123 4567`, which [XUrl.launch] refuses.
  final String url;

  /// What kind of thing was detected.
  final UrlMatchKind kind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UrlMatch &&
          start == other.start &&
          end == other.end &&
          kind == other.kind &&
          url == other.url;

  @override
  int get hashCode => Object.hash(start, end, kind, url);

  @override
  String toString() => 'UrlMatch($kind, [$start,$end), $url)';
}

/// Categorizes a [UrlMatch] for tap routing and styling.
enum UrlMatchKind {
  /// http(s) and custom-scheme URLs.
  web,

  /// Email address → `mailto:` URL.
  email,

  /// Phone number → `tel:` URL.
  phone;

  /// Stable byte tag shared across the FFI boundary and the on-disk codec.
  int get wireByte => index;

  /// Lenient decode: unknown bytes fall back to [web] so a DB row written
  /// by a future build (e.g. a new kind we haven't added yet) still
  /// renders as a tappable link after a downgrade.
  static UrlMatchKind fromByte(int b) {
    if (b >= 0 && b < UrlMatchKind.values.length) {
      return UrlMatchKind.values[b];
    }
    return UrlMatchKind.web;
  }
}
