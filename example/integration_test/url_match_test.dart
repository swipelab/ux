// ignore_for_file: implementation_imports
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/src/url/detect.dart';
import 'package:ux/src/url/phones.dart';
import 'package:ux/url.dart';

import '../../tool/url_window.dart';

UrlMatch _web(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.web);

UrlMatch _email(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.email);

UrlMatch _phone(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.phone);

/// The median of 21 reads of [texts] through [read] after 5 warm-ups, in ms.
double _median(List<String> texts, List<UrlMatch> Function(String) read) {
  for (var i = 0; i < 5; i++) {
    texts.forEach(read);
  }
  final times = <double>[];
  for (var i = 0; i < 21; i++) {
    final watch = Stopwatch()..start();
    texts.forEach(read);
    times.add(watch.elapsedMicroseconds / 1000);
  }
  return (times..sort())[10];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ios = Platform.isIOS;
  final android = Platform.isAndroid;

  testWidgets('a phone links on iOS and Android', (tester) async {
    expect(XUrl.match('call +40 712 345 678 now'), [
      if (ios || android) _phone(5, 20, 'tel:+40712345678'),
    ]);
  });

  testWidgets("banlu's link_open_test text gives its web link, its email and, "
      'on iOS and Android, its phone', (tester) async {
    expect(
      XUrl.match(
        'see https://example.com/a?b=1, mail ops@example.com or call '
        '+40 712 345 678',
      ),
      [
        _web(4, 29, 'https://example.com/a?b=1'),
        _email(36, 51, 'mailto:ops@example.com'),
        if (ios || android) _phone(60, 75, 'tel:+40712345678'),
      ],
    );
  });

  testWidgets("an extension stays out of a phone's URL, and in its span on "
      'iOS', (tester) async {
    expect(XUrl.match('call +1 (555) 123-4567 ext. 89 now'), [
      if (ios) _phone(5, 30, 'tel:+15551234567'),
      if (android) _phone(5, 22, 'tel:+15551234567'),
    ]);
  });

  testWidgets('a phone of fullwidth digits links on iOS', (tester) async {
    expect(
      XUrl.match(
        'call +４０ ７１２ ３４５ '
        '６７８ now',
      ),
      [if (ios) _phone(5, 20, 'tel:+40712345678')],
    );
  });

  testWidgets(
    "reports the phone path's share of the chat window's first scan",
    (tester) async {
      final texts = [for (final m in window(chatMix)) m.text];
      final dart = _median(texts, detectLinks);
      final match = _median(texts, XUrl.match);
      debugPrint(
        'chat window, ${texts.length} messages: detectLinks '
        '${dart.toStringAsFixed(3)} ms, XUrl.match '
        '${match.toStringAsFixed(3)} ms, phone path '
        '${(match - dart).toStringAsFixed(3)} ms, '
        '${texts.where(mayHoldPhone).length} messages read by the platform',
      );
    },
    skip: !(ios || android),
  );
}
