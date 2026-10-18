import 'package:ux/src/url/darwin.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/reading.dart';

/// The links of [text], sorted by [UrlMatch.start] and non-overlapping, with
/// UTF-16 offsets.
List<UrlMatch> detectLinks(String text) => readLinks(text, (s) {
  final raw = nsddResults(s);
  return (candidates: stage2(s, raw), raw: raw);
});
