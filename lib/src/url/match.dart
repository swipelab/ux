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
  /// `tel:<digits>`, email → `mailto:<addr>`. An email or phone whose text
  /// holds a bidi control has its scheme and then that text, or the text
  /// alone where it starts with that scheme, such as `tel:+1`, a right-to-left
  /// mark and `5551234567`, which [XUrl.launch] refuses.
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
  phone,
}
