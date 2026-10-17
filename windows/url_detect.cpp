#include "url_detect.h"

#include <windows.h>

#include <icu.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "tld.h"

namespace {

constexpr uint32_t kKindWeb = 0;
constexpr uint32_t kKindEmail = 1;
constexpr uint32_t kKindPhone = 2;

// Patterns.PHONE matches any run of three or more digits; a dialable number
// has at least this many.
constexpr int kMinPhoneDigits = 7;

struct RawMatch {
  int32_t start;
  int32_t end;
  uint32_t kind;
  std::string url;
};

struct Detectors {
  URegularExpression* web;
  URegularExpression* email;
  URegularExpression* phone;
};

URegularExpression* Compile(const std::u16string& pattern) {
  UErrorCode status = U_ZERO_ERROR;
  UParseError error;
  URegularExpression* regex = uregex_open(pattern.c_str(), static_cast<int32_t>(pattern.size()),
                                          UREGEX_ERROR_ON_UNKNOWN_ESCAPES, &error, &status);
  return U_SUCCESS(status) ? regex : nullptr;
}

// android.util.Patterns' WEB_URL, EMAIL_ADDRESS and PHONE (AOSP, Apache-2.0),
// composed as Patterns.java composes them; a Java surrogate pair is a \U
// escape here. Android compiles them with ICU and
// UREGEX_ERROR_ON_UNKNOWN_ESCAPES, as Compile does.
Detectors CompileDetectors() {
  const std::u16string ucs_char =
      u"["
      u"\u00A0-\uD7FF"
      u"\uF900-\uFDCF"
      u"\uFDF0-\uFFEF"
      u"\U00010000-\U0001FFFD"
      u"\U00020000-\U0002FFFD"
      u"\U00030000-\U0003FFFD"
      u"\U00040000-\U0004FFFD"
      u"\U00050000-\U0005FFFD"
      u"\U00060000-\U0006FFFD"
      u"\U00070000-\U0007FFFD"
      u"\U00080000-\U0008FFFD"
      u"\U00090000-\U0009FFFD"
      u"\U000A0000-\U000AFFFD"
      u"\U000B0000-\U000BFFFD"
      u"\U000C0000-\U000CFFFD"
      u"\U000D0000-\U000DFFFD"
      u"\U000E1000-\U000EFFFD"
      u"&&[^\u00A0[\u2000-\u200A]\u2028\u2029\u202F\u3000]]";
  const std::u16string ip_address_string =
      u"((25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9])\\.(25[0-5]|2[0-4]"
      u"[0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)\\.(25[0-5]|2[0-4][0-9]|[0-1]"
      u"[0-9]{2}|[1-9][0-9]|[1-9]|0)\\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}"
      u"|[1-9][0-9]|[0-9]))";
  const std::u16string label_char = u"a-zA-Z0-9" + ucs_char;
  const std::u16string tld_char = u"a-zA-Z" + ucs_char;
  const std::u16string iri_label =
      u"[" + label_char + u"](?:[" + label_char + u"_\\-]{0,61}[" + label_char + u"]){0,1}";
  const std::u16string punycode_tld = u"xn\\-\\-[\\w\\-]{0,58}\\w";
  const std::u16string tld = u"(" + punycode_tld + u"|" + u"[" + tld_char + u"]{2,63}" + u")";
  const std::u16string host_name = u"(" + iri_label + u"\\.)+" + tld;
  const std::u16string domain_name_str = u"(" + host_name + u"|" + ip_address_string + u")";
  const std::u16string protocol = u"(?i:http|https|rtsp|ftp)://";
  const std::u16string word_boundary = u"(?:\\b|$|^)";
  const std::u16string user_info =
      u"(?:[a-zA-Z0-9\\$\\-\\_\\.\\+\\!\\*\\'\\(\\)"
      u"\\,\\;\\?\\&\\=]|(?:\\%[a-fA-F0-9]{2})){1,64}(?:\\:(?:[a-zA-Z0-9\\$\\-\\_"
      u"\\.\\+\\!\\*\\'\\(\\)\\,\\;\\?\\&\\=]|(?:\\%[a-fA-F0-9]{2})){1,25})?\\@";
  const std::u16string port_number = u"\\:\\d{1,5}";
  const std::u16string path_and_query = u"[/\\?](?:(?:[" + label_char +
                                        u";/\\?:@&=#~"
                                        u"\\-\\.\\+!\\*'\\(\\),_\\$])|(?:%[a-fA-F0-9]{2}))*";
  const std::u16string web_url = u"("
                                 u"("
                                 u"(?:" + protocol + u"(?:" + user_info + u")?" + u")?" +
                                 u"(?:" + domain_name_str + u")" +
                                 u"(?:" + port_number + u")?" +
                                 u")" +
                                 u"(" + path_and_query + u")?" +
                                 word_boundary +
                                 u")";
  const std::u16string email_address =
      u"[a-zA-Z0-9\\+\\.\\_\\%\\-\\+]{1,256}"
      u"\\@"
      u"[a-zA-Z0-9][a-zA-Z0-9\\-]{0,64}"
      u"("
      u"\\."
      u"[a-zA-Z0-9][a-zA-Z0-9\\-]{0,25}"
      u")+";
  const std::u16string phone =
      u"(\\+[0-9]+[\\- \\.]*)?"
      u"(\\([0-9]+\\)[\\- \\.]*)?"
      u"([0-9][0-9\\- \\.]+[0-9])";
  return Detectors{Compile(web_url), Compile(email_address), Compile(phone)};
}

const Detectors& Compiled() {
  static const Detectors detectors = CompileDetectors();
  return detectors;
}

std::string Utf8(const UChar* text, int32_t len) {
  const auto* wide = reinterpret_cast<const wchar_t*>(text);
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide, len, nullptr, 0, nullptr, nullptr);
  std::string utf8(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, len, utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// A match with a scheme as it is; Patterns.WEB_URL also matches bare domains
// and www., which open as http://.
std::string CanonicalWebUrl(const std::string& match) {
  for (size_t i = 0; i < match.size(); i++) {
    const char c = match[i];
    if (c == ':') {
      if (i + 2 < match.size() && match[i + 1] == '/' && match[i + 2] == '/') return match;
      break;
    }
    const auto u = static_cast<unsigned char>(c);
    if (!(std::isalpha(u) || std::isdigit(u) || c == '+' || c == '.' || c == '-')) break;
  }
  return "http://" + match;
}

// tel: with the match's digits and plus signs, or none below kMinPhoneDigits.
std::optional<std::string> CanonicalPhone(const std::string& match) {
  std::string dialed;
  int digits = 0;
  for (const char c : match) {
    if (c >= '0' && c <= '9') {
      dialed.push_back(c);
      digits++;
    } else if (c == '+') {
      dialed.push_back(c);
    }
  }
  if (digits < kMinPhoneDigits) return std::nullopt;
  return "tel:" + dialed;
}

// Whether the detector matches [start, end) of the text whole.
bool MatchesWhole(const URegularExpression* detector, const UChar* text, int32_t len, int32_t start, int32_t end) {
  UErrorCode status = U_ZERO_ERROR;
  URegularExpression* regex = uregex_clone(detector, &status);
  uregex_setText(regex, text, len, &status);
  uregex_setRegion(regex, start, end, &status);
  const bool whole = uregex_matches(regex, -1, &status) && U_SUCCESS(status);
  uregex_close(regex);
  return whole;
}

// Whether c is path punctuation a URL may end in, or sentence punctuation or
// ')' that WebEnd weighs. A quote or '(' after a link belongs to the text
// around it.
bool IsPathEnd(UChar c) { return std::u16string_view(u"/?:@&=#~-+*$).,;!").find(c) != std::u16string_view::npos; }

// Whether c belongs to a script whose text runs onto a domain with no space
// between: Han, kana, Bopomofo, Hangul, Thai, Lao, Khmer and Myanmar by block,
// and an ideograph of the supplementary planes by its high surrogate.
bool IsUnspaced(UChar c) {
  return (c >= 0x0E00 && c <= 0x0EFF) || (c >= 0x1000 && c <= 0x109F) || (c >= 0x1100 && c <= 0x11FF) ||
         (c >= 0x1780 && c <= 0x17FF) || (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xA960 && c <= 0xA97F) ||
         (c >= 0xAC00 && c <= 0xD7FF) || (c >= 0xD840 && c <= 0xD8BF) || (c >= 0xF900 && c <= 0xFAFF) ||
         (c >= 0xFF66 && c <= 0xFFDC);
}

// The end of the web match [start, end) in the region that ends at `to`.
// Patterns.WEB_URL ends a match on a word boundary, which leaves out a path's
// trailing punctuation where text follows it and a port where unspaced letters
// follow it. The match runs on through the IsPathEnd punctuation after it, and
// through the digits after that where unspaced letters follow them, when the
// detector matches the span to there whole, then ends before a trailing '.',
// ',', ';', '!', '\'' or '(' and a trailing ')' it does not open.
int32_t WebEnd(const URegularExpression* detector, const UChar* text, int32_t len, int32_t start, int32_t end,
               int32_t to) {
  int32_t tail = end;
  while (tail < to && IsPathEnd(text[tail])) tail++;
  int32_t digits = tail;
  while (digits < to && text[digits] >= u'0' && text[digits] <= u'9') digits++;
  if (digits < to && IsUnspaced(text[digits])) tail = digits;
  if (tail > end && MatchesWhole(detector, text, len, start, tail)) end = tail;
  int32_t unopened = 0;
  for (int32_t i = start; i < end; i++) {
    if (text[i] == u')') unopened++;
    if (text[i] == u'(') unopened--;
  }
  while (end > start) {
    const UChar c = text[end - 1];
    if (c == u')' && unopened > 0) {
      unopened--;
    } else if (c == u'(') {
      unopened++;
    } else if (!(c == u'.' || c == u',' || c == u';' || c == u'!' || c == u'\'')) {
      break;
    }
    end--;
  }
  return end;
}

// U+3000's block's punctuation and the vertical, compatibility, small,
// fullwidth and halfwidth forms of punctuation.
bool IsCjkPunctuation(UChar c) {
  return (c >= 0x3001 && c <= 0x3003) || (c >= 0x3008 && c <= 0x3011) || (c >= 0x3014 && c <= 0x301F) ||
         (c >= 0xFE10 && c <= 0xFE19) || (c >= 0xFE30 && c <= 0xFE6B) || (c >= 0xFF01 && c <= 0xFF0F) ||
         (c >= 0xFF1A && c <= 0xFF20) || (c >= 0xFF3B && c <= 0xFF40) || (c >= 0xFF5B && c <= 0xFF65);
}

// The glue of the host that begins the web match [start, end), which ends at
// its first change between unspaced letters and other characters inside a
// label: the '.' after the unspaced labels that begin the host, else the '.'
// before those that end it, else that change. A low surrogate goes with its
// high surrogate.
std::optional<int32_t> HostGlue(const UChar* text, int32_t start, int32_t end) {
  const bool leading = IsUnspaced(text[start]);
  bool unspaced = leading;
  std::optional<int32_t> glue;
  for (int32_t i = start + 1; i < end; i++) {
    const UChar c = text[i];
    if (c == u'.' || (c >= 0xDC00 && c <= 0xDFFF)) continue;
    if (c < 0x80 && !(std::isalnum(c) || c == u'-' || c == u'_')) break;
    if (IsUnspaced(c) == unspaced) continue;
    unspaced = !unspaced;
    if (text[i - 1] != u'.') return glue.value_or(i);
    if (leading) return i - 1;
    if (unspaced) {
      glue = i - 1;
    } else {
      glue.reset();
    }
  }
  return glue;
}

// Whether the web match [start, end) has the TLD it needs: a match with a
// scheme or an IP address needs none, and a host's last label is one where
// IsTld holds. Patterns.WEB_URL takes any letters after a host's last '.' for
// its TLD, so a word a period glues to a bare domain joins it.
bool HasTld(const UChar* text, int32_t start, int32_t end) {
  int32_t host_end = start;
  while (host_end < end && std::u16string_view(u":/?").find(text[host_end]) == std::u16string_view::npos) host_end++;
  if (host_end + 2 < end && text[host_end] == u':' && text[host_end + 1] == u'/' && text[host_end + 2] == u'/') {
    return true;
  }
  int32_t label = host_end;
  while (label > start && text[label - 1] != u'.') label--;
  return (text[label] >= u'0' && text[label] <= u'9') || IsTld(std::u16string_view(text + label, host_end - label));
}

bool IsPathDelimiter(UChar c) { return std::u16string_view(u"/?#&=").find(c) != std::u16string_view::npos; }

// A clone per call, since a URegularExpression holds its matcher's state.
// Each stretch of the text between CJK punctuation is a region the detector
// matches as a text of its own, so no link takes a mark in. Past a web link
// the region cuts at a fullwidth '(', a web match in a stretch after a
// fullwidth ')' is that link's path where the stretch holds a path delimiter
// before it and the detector matches the link through it whole. No host runs
// across its glue: the web match is the part before the glue where the
// detector matches that whole, and the search goes on from the glue. A phone
// match that Patterns.WEB_URL matches whole is a dotted IPv4 address, no
// phone, unless it starts with a '0', a national trunk prefix; the address is
// a web link where an unspaced letter follows it, since no word boundary ends a
// Patterns.WEB_URL match there.
void Find(const URegularExpression* detector, const UChar* text, int32_t len, uint32_t kind,
          std::vector<RawMatch>& out) {
  UErrorCode status = U_ZERO_ERROR;
  URegularExpression* regex = uregex_clone(detector, &status);
  uregex_setText(regex, text, len, &status);
  std::optional<int32_t> cut;
  for (int32_t from = 0; from <= len;) {
    int32_t to = from;
    while (to < len && !IsCjkPunctuation(text[to])) to++;
    uregex_setRegion(regex, from, to, &status);
    while (uregex_findNext(regex, &status)) {
      const int32_t start = uregex_start(regex, 0, &status);
      int32_t end = uregex_end(regex, 0, &status);
      if (U_FAILURE(status)) break;
      if (kind == kKindWeb) {
        if (cut && text[from - 1] == u'\uFF09' && std::any_of(text + from, text + start, IsPathDelimiter) &&
            MatchesWhole(detector, text, len, *cut, end)) continue;
        if (const std::optional<int32_t> glue = HostGlue(text, start, end)) {
          uregex_setRegion(regex, *glue, to, &status);
          if (!MatchesWhole(detector, text, len, start, *glue)) continue;
          end = *glue;
        }
        if (!HasTld(text, start, end)) continue;
        if (end == to && to < len && text[to] == u'\uFF08') cut = start;
        end = WebEnd(detector, text, len, start, end, to);
      }
      uint32_t found = kind;
      if (kind == kKindPhone && text[start] != u'0' && MatchesWhole(Compiled().web, text, len, start, end)) {
        if (end == len || !IsUnspaced(text[end])) continue;
        found = kKindWeb;
      }
      const std::string group = Utf8(text + start, end - start);
      std::optional<std::string> url = found == kKindWeb     ? CanonicalWebUrl(group)
                                       : found == kKindEmail ? "mailto:" + group
                                                             : CanonicalPhone(group);
      if (url) out.push_back(RawMatch{start, end, found, std::move(*url)});
    }
    from = to + 1;
  }
  uregex_close(regex);
}

// By start; at the same start the longer match, then the higher kind. A match
// starting inside a kept one goes.
void KeepLongestFirst(std::vector<RawMatch>& matches) {
  std::sort(matches.begin(), matches.end(), [](const RawMatch& a, const RawMatch& b) {
    if (a.start != b.start) return a.start < b.start;
    if (a.end - a.start != b.end - b.start) return a.end - a.start > b.end - b.start;
    return a.kind > b.kind;
  });
  std::vector<RawMatch> kept;
  for (auto& m : matches) {
    if (!kept.empty() && m.start < kept.back().end) continue;
    kept.push_back(std::move(m));
  }
  matches.swap(kept);
}

uint8_t* Serialize(const std::vector<RawMatch>& matches, int32_t* out_size) {
  size_t total = 4;
  for (const auto& m : matches) total += 16 + m.url.size();
  auto* buf = static_cast<uint8_t*>(std::malloc(total));
  if (buf == nullptr) return nullptr;
  const auto count = static_cast<uint32_t>(matches.size());
  std::memcpy(buf, &count, 4);
  size_t offset = 4;
  for (const auto& m : matches) {
    const auto url_len = static_cast<uint32_t>(m.url.size());
    std::memcpy(buf + offset, &m.start, 4);
    std::memcpy(buf + offset + 4, &m.end, 4);
    std::memcpy(buf + offset + 8, &m.kind, 4);
    std::memcpy(buf + offset + 12, &url_len, 4);
    std::memcpy(buf + offset + 16, m.url.data(), url_len);
    offset += 16 + url_len;
  }
  *out_size = static_cast<int32_t>(total);
  return buf;
}

}  // namespace

uint8_t* ux_match_url(const uint16_t* utf16, int32_t len, int32_t* out_size) {
  *out_size = 0;
  const Detectors& detectors = Compiled();
  const auto* text = reinterpret_cast<const UChar*>(utf16);
  std::vector<RawMatch> matches;
  Find(detectors.web, text, len, kKindWeb, matches);
  Find(detectors.email, text, len, kKindEmail, matches);
  Find(detectors.phone, text, len, kKindPhone, matches);
  KeepLongestFirst(matches);
  if (matches.empty()) return nullptr;
  return Serialize(matches, out_size);
}

void ux_free(uint8_t* buf) { std::free(buf); }
