import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/url.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a comma ending the text stays out of the web link',
      (tester) async {
    expect(XUrl.match('see https://example.com/a?b=1,'), const [
      UrlMatch(
          start: 4,
          end: 29,
          url: 'https://example.com/a?b=1',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets('a question mark ending the text stays in the web link',
      (tester) async {
    expect(XUrl.match('see https://example.com/a?'), const [
      UrlMatch(
          start: 4,
          end: 26,
          url: 'https://example.com/a?',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets(
      'a closing parenthesis a bare domain link opens stays in it, '
      'one it does not open goes', (tester) async {
    expect(XUrl.match('(see example.com/a_(b)).'), const [
      UrlMatch(
          start: 5,
          end: 22,
          url: 'http://example.com/a_(b)',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets(
      'a slash ending the path stays in the web link where text follows',
      (tester) async {
    expect(XUrl.match('see www.example.com/ x'), const [
      UrlMatch(
          start: 4,
          end: 20,
          url: 'http://www.example.com/',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets(
      'a closing parenthesis the web link opens stays in it where text follows',
      (tester) async {
    expect(XUrl.match('see https://example.com/a_(b), x'), const [
      UrlMatch(
          start: 4,
          end: 29,
          url: 'https://example.com/a_(b)',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets('a colon after a host stays out of the web link', (tester) async {
    expect(XUrl.match('see example.com: x'), const [
      UrlMatch(
          start: 4,
          end: 15,
          url: 'http://example.com',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets('a web link ends before CJK punctuation', (tester) async {
    expect(XUrl.match('看 https://example.com/a?b=1。下一句'), const [
      UrlMatch(
          start: 2,
          end: 27,
          url: 'https://example.com/a?b=1',
          kind: UrlMatchKind.web),
    ]);
  });

  testWidgets(
      'a bare domain link between CJK punctuation takes in neither mark',
      (tester) async {
    expect(XUrl.match('链接：example.com/a。下'), const [
      UrlMatch(
          start: 3,
          end: 16,
          url: 'http://example.com/a',
          kind: UrlMatchKind.web),
    ]);
  });
}
