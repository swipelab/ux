import 'package:ux/src/url/darwin.dart';
import 'package:ux/src/url/reading.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd_model.dart';

/// The links of [text], sorted by [UrlMatch.start] and non-overlapping, with
/// UTF-16 offsets.
List<UrlMatch> detectLinks(String text) =>
    readLinks(text, (s) => (candidates: stage2(s), raw: nsddResults(s)));
