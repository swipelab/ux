#include "url_detect.h"

#include <windows.h>

#include <icu.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

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

// The end of the web match [start, end) before its trailing sentence
// punctuation and a trailing ')' it does not open, which Patterns.WEB_URL takes
// into a match that ends the text.
int32_t WebEnd(const UChar* text, int32_t start, int32_t end) {
  int32_t unopened = 0;
  for (int32_t i = start; i < end; i++) {
    if (text[i] == u')') unopened++;
    if (text[i] == u'(') unopened--;
  }
  while (end > start) {
    const UChar c = text[end - 1];
    if (c == u')' && unopened > 0) {
      unopened--;
    } else if (!(c == u'.' || c == u',' || c == u';' || c == u':' || c == u'!' || c == u'?')) {
      break;
    }
    end--;
  }
  return end;
}

// A clone per call, since a URegularExpression holds its matcher's state.
void Find(const URegularExpression* detector, const UChar* text, int32_t len, uint32_t kind,
          std::vector<RawMatch>& out) {
  UErrorCode status = U_ZERO_ERROR;
  URegularExpression* regex = uregex_clone(detector, &status);
  uregex_setText(regex, text, len, &status);
  while (uregex_findNext(regex, &status)) {
    const int32_t start = uregex_start(regex, 0, &status);
    const int32_t matched = uregex_end(regex, 0, &status);
    if (U_FAILURE(status)) break;
    const int32_t end = kind == kKindWeb ? WebEnd(text, start, matched) : matched;
    const std::string group = Utf8(text + start, end - start);
    std::optional<std::string> url = kind == kKindWeb     ? CanonicalWebUrl(group)
                                     : kind == kKindEmail ? "mailto:" + group
                                                          : CanonicalPhone(group);
    if (url) out.push_back(RawMatch{start, end, kind, std::move(*url)});
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
