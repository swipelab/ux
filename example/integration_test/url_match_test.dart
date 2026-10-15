import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ux/url.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a comma ending the text stays out of the web link', (
    tester,
  ) async {
    expect(XUrl.match('see https://example.com/a?b=1,'), const [
      UrlMatch(
        start: 4,
        end: 29,
        url: 'https://example.com/a?b=1',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a question mark ending the text stays in the web link', (
    tester,
  ) async {
    expect(XUrl.match('see https://example.com/a?'), const [
      UrlMatch(
        start: 4,
        end: 26,
        url: 'https://example.com/a?',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a closing parenthesis a bare domain link opens stays in it, '
      'one it does not open goes', (tester) async {
    expect(XUrl.match('(see example.com/a_(b)).'), const [
      UrlMatch(
        start: 5,
        end: 22,
        url: 'http://example.com/a_(b)',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets(
    'a closing parenthesis a web link with a scheme does not open stays out '
    'of it',
    (tester) async {
      expect(XUrl.match('(see https://example.com/a_(b)).'), const [
        UrlMatch(
          start: 5,
          end: 30,
          url: 'https://example.com/a_(b)',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('a closing quote stays out of a web link with a scheme', (
    tester,
  ) async {
    expect(XUrl.match("He said 'https://example.com/a'."), const [
      UrlMatch(
        start: 9,
        end: 30,
        url: 'https://example.com/a',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a bare domain link ends before a double quote', (tester) async {
    expect(XUrl.match('see "example.com/a" x'), const [
      UrlMatch(
        start: 5,
        end: 18,
        url: 'http://example.com/a',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets(
    'a web link that holds a parenthesis ends before a square bracket',
    (tester) async {
      expect(
        XUrl.match('[see https://en.wikipedia.org/wiki/Foo_(bar)] x'),
        const [
          UrlMatch(
            start: 5,
            end: 44,
            url: 'https://en.wikipedia.org/wiki/Foo_(bar)',
            kind: UrlMatchKind.web,
          ),
        ],
      );
    },
  );

  testWidgets(
    'a web link a vertical bar ends opens the text it covers, an unclosed '
    'parenthesis included',
    (tester) async {
      expect(
        XUrl.match('see https://www.google.com/search?q=(cats|dogs) x'),
        const [
          UrlMatch(
            start: 4,
            end: 41,
            url: 'https://www.google.com/search?q=(cats',
            kind: UrlMatchKind.web,
          ),
        ],
      );
    },
  );

  testWidgets(
    'a closing parenthesis a web link does not open goes with the quote '
    'after it',
    (tester) async {
      expect(
        XUrl.match("'(see https://en.wikipedia.org/wiki/Foo_(bar))' x"),
        const [
          UrlMatch(
            start: 6,
            end: 45,
            url: 'https://en.wikipedia.org/wiki/Foo_(bar)',
            kind: UrlMatchKind.web,
          ),
        ],
      );
    },
  );

  testWidgets(
    'a closing parenthesis a bare domain link does not open goes with the '
    'square bracket after it',
    (tester) async {
      expect(XUrl.match('(see example.com/a_(b))] x'), const [
        UrlMatch(
          start: 5,
          end: 22,
          url: 'http://example.com/a_(b)',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets(
    'an opening parenthesis ending the text stays out of the web link',
    (tester) async {
      expect(XUrl.match('see https://example.com/a('), const [
        UrlMatch(
          start: 4,
          end: 25,
          url: 'https://example.com/a',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('a web link with a scheme ends before a closing angle bracket', (
    tester,
  ) async {
    expect(XUrl.match('see <https://example.com/a> x'), const [
      UrlMatch(
        start: 5,
        end: 26,
        url: 'https://example.com/a',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets(
    'the escapes of a web link a square bracket ends stay as the text has them',
    (tester) async {
      expect(XUrl.match('see https://example.com/a%20b] x'), const [
        UrlMatch(
          start: 4,
          end: 29,
          url: 'https://example.com/a%20b',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('an IP literal host keeps its square brackets in the web link', (
    tester,
  ) async {
    expect(XUrl.match('see http://[::1]:8080/a x'), const [
      UrlMatch(
        start: 4,
        end: 23,
        url: 'http://[::1]:8080/a',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a userinfo before an IP literal host stays in the web link', (
    tester,
  ) async {
    expect(XUrl.match('see http://user@[::1]/a x'), const [
      UrlMatch(
        start: 4,
        end: 23,
        url: 'http://user@[::1]/a',
        kind: UrlMatchKind.web,
      ),
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
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets(
    'a closing parenthesis the web link opens stays in it where text follows',
    (tester) async {
      expect(XUrl.match('see https://example.com/a_(b), x'), const [
        UrlMatch(
          start: 4,
          end: 29,
          url: 'https://example.com/a_(b)',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('a colon after a host stays out of the web link', (tester) async {
    expect(XUrl.match('see example.com: x'), const [
      UrlMatch(
        start: 4,
        end: 15,
        url: 'http://example.com',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a word a period glues to a bare domain makes it no link', (
    tester,
  ) async {
    expect(XUrl.match('see example.com.Then you'), const <UrlMatch>[]);
  });

  testWidgets(
    'a capitalised word a period glues to a bare domain makes it no link, '
    'though its lowercase is a TLD',
    (tester) async {
      expect(XUrl.match('see example.com.It works'), const <UrlMatch>[]);
    },
  );

  testWidgets(
    'a word outside ASCII a period glues to a bare domain makes it no link',
    (tester) async {
      expect(XUrl.match('see example.com.Über x'), const <UrlMatch>[]);
    },
  );

  testWidgets('a bare domain links on com, edu, gov, net or org in capitals', (
    tester,
  ) async {
    expect(XUrl.match('see EXAMPLE.COM x'), const [
      UrlMatch(
        start: 4,
        end: 15,
        url: 'http://EXAMPLE.COM',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a web link ends before CJK punctuation', (tester) async {
    expect(XUrl.match('看 https://example.com/a?b=1。下一句'), const [
      UrlMatch(
        start: 2,
        end: 27,
        url: 'https://example.com/a?b=1',
        kind: UrlMatchKind.web,
      ),
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
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets(
    'the path a web link runs on into past CJK punctuation does not link '
    'on its own',
    (tester) async {
      expect(XUrl.match('https://example.com/a（1）/page.html'), const [
        UrlMatch(
          start: 0,
          end: 21,
          url: 'https://example.com/a',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets(
    "a bare domain past a web link's CJK punctuation with no path delimiter "
    'before it links on its own',
    (tester) async {
      expect(XUrl.match('https://example.com/a，备用:example.org'), const [
        UrlMatch(
          start: 0,
          end: 21,
          url: 'https://example.com/a',
          kind: UrlMatchKind.web,
        ),
        UrlMatch(
          start: 25,
          end: 36,
          url: 'http://example.org',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets(
    "a bare domain past a web link's CJK punctuation and a space links on "
    'its own',
    (tester) async {
      expect(XUrl.match('https://example.com/a（1） see/example.org'), const [
        UrlMatch(
          start: 0,
          end: 21,
          url: 'https://example.com/a',
          kind: UrlMatchKind.web,
        ),
        UrlMatch(
          start: 29,
          end: 40,
          url: 'http://example.org',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('a bare domain glued after CJK letters leaves them out', (
    tester,
  ) async {
    expect(XUrl.match('访问example.com，然后'), const [
      UrlMatch(
        start: 2,
        end: 13,
        url: 'http://example.com',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('CJK letters glued after a bare domain stay out of it', (
    tester,
  ) async {
    expect(XUrl.match('example.com然后'), const [
      UrlMatch(
        start: 0,
        end: 11,
        url: 'http://example.com',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets(
    'a bare domain leaves out a period and the CJK letters after it',
    (tester) async {
      expect(XUrl.match('请看example.com.谢谢'), const [
        UrlMatch(
          start: 2,
          end: 13,
          url: 'http://example.com',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('CJK letters between two bare domains stay out of both', (
    tester,
  ) async {
    expect(XUrl.match('访问example.com和google.com'), const [
      UrlMatch(
        start: 2,
        end: 13,
        url: 'http://example.com',
        kind: UrlMatchKind.web,
      ),
      UrlMatch(
        start: 14,
        end: 24,
        url: 'http://google.com',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets(
    'a vertical bar between two bare domain links stays out of both',
    (tester) async {
      expect(XUrl.match('see example.com/a|example.org/b z'), const [
        UrlMatch(
          start: 4,
          end: 17,
          url: 'http://example.com/a',
          kind: UrlMatchKind.web,
        ),
        UrlMatch(
          start: 18,
          end: 31,
          url: 'http://example.org/b',
          kind: UrlMatchKind.web,
        ),
      ]);
    },
  );

  testWidgets('a port CJK letters follow stays in the bare domain link', (
    tester,
  ) async {
    expect(XUrl.match('访问example.com:8080然后'), const [
      UrlMatch(
        start: 2,
        end: 18,
        url: 'http://example.com:8080',
        kind: UrlMatchKind.web,
      ),
    ]);
  });

  testWidgets('a bare domain glued after Thai letters leaves them out', (
    tester,
  ) async {
    expect(XUrl.match('ข้อมูลที่example.com'), const [
      UrlMatch(
        start: 9,
        end: 20,
        url: 'http://example.com',
        kind: UrlMatchKind.web,
      ),
    ]);
  });
}
