import 'package:flutter_test/flutter_test.dart';
import 'package:ux/url.dart';

/// A web link over [start, end) opening [url].
UrlMatch web(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.web);

/// An email link over [start, end) opening [url].
UrlMatch email(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.email);

/// A phone link over [start, end) opening [url].
UrlMatch phone(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.phone);

/// XUrl.match's links of [text], which hold no phone on the host.
List<UrlMatch> linksOf(String text) => XUrl.match(text);

/// Expects the links of [text] to be [expected]. [apple] is the darwin
/// reading where [expected] departs from it, which oracle mode checks.
void expectLinks(
  String text,
  List<UrlMatch> expected, {
  List<UrlMatch>? apple,
}) {
  expect(linksOf(text), expected);
}
