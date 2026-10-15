#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "../url_detect.h"
#include "check.h"

namespace {

constexpr uint32_t kWeb = 0;
constexpr uint32_t kEmail = 1;
constexpr uint32_t kPhone = 2;

struct Match {
  int32_t start;
  int32_t end;
  uint32_t kind;
  std::string url;

  bool operator==(const Match& other) const {
    return start == other.start && end == other.end && kind == other.kind && url == other.url;
  }
};

struct Case {
  const char* name;
  std::u16string text;
  std::vector<Match> expected;
};

const std::u16string kStepText = u"see https://example.com/a?b=1, mail ops@example.com or call +40 712 345 678";

const std::vector<Case>& Corpus() {
  static const std::vector<Case> corpus = {
      {"a web link, an email and a + phone",
       kStepText,
       {{4, 29, kWeb, "https://example.com/a?b=1"},
        {36, 51, kEmail, "mailto:ops@example.com"},
        {60, 75, kPhone, "tel:+40712345678"}}},
      {"a comma ending the text stays out of the web link",
       u"see https://example.com/a?b=1,",
       {{4, 29, kWeb, "https://example.com/a?b=1"}}},
      {"a question mark ending the text stays in the web link",
       u"see https://example.com/a?",
       {{4, 26, kWeb, "https://example.com/a?"}}},
      {"a closing parenthesis the web link opens stays in it, one it does not open goes",
       u"(see https://example.com/a_(b)).",
       {{5, 30, kWeb, "https://example.com/a_(b)"}}},
      {"a slash ending the path stays in the web link where text follows",
       u"see www.example.com/ x",
       {{4, 20, kWeb, "http://www.example.com/"}}},
      {"a closing parenthesis the web link opens stays in it where text follows",
       u"see https://example.com/a_(b), x",
       {{4, 29, kWeb, "https://example.com/a_(b)"}}},
      {"a colon after a host stays out of the web link", u"see example.com: x", {{4, 15, kWeb, "http://example.com"}}},
      {"a web link ends before CJK punctuation",
       u"\u770B https://example.com/a?b=1\u3002\u4E0B\u4E00\u53E5",
       {{2, 27, kWeb, "https://example.com/a?b=1"}}},
      {"a bare domain link between CJK punctuation takes in neither mark",
       u"\u94FE\u63A5\uFF1Aexample.com/a\u3002\u4E0B",
       {{3, 16, kWeb, "http://example.com/a"}}},
      {"a bare domain glued after CJK letters leaves them out",
       u"访问example.com，然后",
       {{2, 13, kWeb, "http://example.com"}}},
      {"CJK letters glued after a bare domain stay out of it",
       u"example.com然后",
       {{0, 11, kWeb, "http://example.com"}}},
      {"a bare domain's labels may differ in script",
       u"看 example.中国 吧",
       {{2, 12, kWeb, u8"http://example.中国"}}},
      {"http with a port, a path and a query",
       u"http://example.com:8080/a/b?c=d&e=f",
       {{0, 35, kWeb, "http://example.com:8080/a/b?c=d&e=f"}}},
      {"www. with a path and a query", u"www.example.com/path?q=1", {{0, 24, kWeb, "http://www.example.com/path?q=1"}}},
      {"a bare domain with a port, a path and a query",
       u"example.org:8443/docs?id=7",
       {{0, 26, kWeb, "http://example.org:8443/docs?id=7"}}},
      {"an IRI host and path",
       u"visit https://b\u00FCcher.example/stra\u00DFe today",
       {{6, 35, kWeb, u8"https://b\u00FCcher.example/stra\u00DFe"}}},
      {"a bare IRI host",
       u"\u8BBF\u95EE \u4F8B\u5B50.\u6D4B\u8BD5 \u5427",
       {{3, 8, kWeb, u8"http://\u4F8B\u5B50.\u6D4B\u8BD5"}}},
      {"an email over the web match at its start",
       u"write to first.last+tag@sub.example.co.uk today",
       {{9, 41, kEmail, "mailto:first.last+tag@sub.example.co.uk"}}},
      {"an (area) phone", u"call (021) 555-0199 today", {{5, 19, kPhone, "tel:0215550199"}}},
      {"a 0-leading phone", u"home 0731098515", {{5, 15, kPhone, "tel:0731098515"}}},
      {"six digits are no phone, seven are", u"pin 12-34-56 or 555-0199", {{16, 24, kPhone, "tel:5550199"}}},
      {"a web match over the phone at its start", u"ip 123.45.67.89/x", {{3, 17, kWeb, "http://123.45.67.89/x"}}},
      {"UTF-16 offsets after a supplementary character",
       u"\U0001F600 ops@example.com or https://example.com/\U0001F600",
       {{3, 18, kEmail, "mailto:ops@example.com"}, {22, 44, kWeb, u8"https://example.com/\U0001F600"}}},
      {"no link", u"nothing to see here", {}},
  };
  return corpus;
}

// The entries of ux_match_url's wire layout, which fill its buffer exactly.
std::vector<Match> Read(const uint8_t* buf, int32_t size) {
  std::vector<Match> matches;
  if (buf == nullptr) {
    CHECK(size == 0);
    return matches;
  }
  const auto end = static_cast<size_t>(size);
  const auto u32 = [buf](size_t at) {
    uint32_t value;
    std::memcpy(&value, buf + at, 4);
    return value;
  };
  CHECK(end >= 4);
  size_t offset = 4;
  for (uint32_t i = 0, count = u32(0); i < count; i++) {
    CHECK(offset + 16 <= end);
    if (offset + 16 > end) break;
    const uint32_t url_len = u32(offset + 12);
    CHECK(offset + 16 + url_len <= end);
    if (offset + 16 + url_len > end) break;
    matches.push_back(Match{static_cast<int32_t>(u32(offset)), static_cast<int32_t>(u32(offset + 4)),
                            u32(offset + 8), std::string(reinterpret_cast<const char*>(buf + offset + 16), url_len)});
    offset += 16 + url_len;
  }
  CHECK(offset == end);
  return matches;
}

std::vector<Match> Detect(const std::u16string& text) {
  int32_t size = -1;
  uint8_t* buf = ux_match_url(reinterpret_cast<const uint16_t*>(text.data()), static_cast<int32_t>(text.size()), &size);
  std::vector<Match> matches = Read(buf, size);
  ux_free(buf);
  return matches;
}

void Print(const char* label, const std::vector<Match>& matches) {
  std::printf("  %s:\n", label);
  for (const Match& m : matches) std::printf("    [%d, %d) kind %u %s\n", m.start, m.end, m.kind, m.url.c_str());
}

// Two threads detect the corpus over and over from the first call, which
// compiles the patterns.
void ExpectTwoThreads() {
  std::atomic<int> mismatches{0};
  const auto run = [&mismatches] {
    for (int round = 0; round < 200; round++) {
      for (const Case& c : Corpus()) {
        if (!(Detect(c.text) == c.expected)) mismatches++;
      }
    }
  };
  std::thread first(run);
  std::thread second(run);
  first.join();
  second.join();
  CHECK(mismatches == 0);
}

void ExpectCorpus() {
  for (const Case& c : Corpus()) {
    const std::vector<Match> actual = Detect(c.text);
    CHECK(actual == c.expected);
    if (actual == c.expected) continue;
    std::printf("%s\n", c.name);
    Print("expected", c.expected);
    Print("actual", actual);
  }
}

void ExpectWireLayout() {
  int32_t size = -1;
  uint8_t* buf =
      ux_match_url(reinterpret_cast<const uint16_t*>(kStepText.data()), static_cast<int32_t>(kStepText.size()), &size);
  CHECK(size == 4 + (16 + 25) + (16 + 22) + (16 + 16));
  const uint8_t head[] = {3, 0, 0, 0, 4, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0, 25, 0, 0, 0};
  CHECK(buf != nullptr && std::memcmp(buf, head, sizeof(head)) == 0);
  CHECK(buf != nullptr && std::memcmp(buf + sizeof(head), "https://example.com/a?b=1", 25) == 0);
  ux_free(buf);
}

}  // namespace

void UrlDetectSuite() {
  ExpectTwoThreads();
  ExpectCorpus();
  ExpectWireLayout();
}
