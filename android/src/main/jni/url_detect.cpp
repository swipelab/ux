// Native data detection for XUrl on Android. Synchronous, callable via dart:ffi.
//
// Exports two symbols:
//   uint8_t* ux_match_url(const uint16_t* utf16, int32_t len, int32_t* out_size);
//   void     ux_free(uint8_t* buf);
//
// Output buffer layout (little-endian):
//   u32 count
//   count * { i32 start, i32 end, u32 kind, u32 url_len, u8[url_len] url_utf8 }
// where kind ∈ { 0=web, 1=email, 2=phone }.
//
// Backed by `android.util.Patterns.WEB_URL` / `EMAIL_ADDRESS` / `PHONE` via
// JNI — so we ship the exact AOSP regexes that `Linkify` uses, kept in sync
// by the platform. No hand-rolled patterns to maintain.

#include <android/log.h>
#include <jni.h>
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "tld.h"

#define UX_LOG_TAG "XUrl"
#define UX_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, UX_LOG_TAG, __VA_ARGS__)

namespace {

constexpr uint32_t kKindWeb = 0;
constexpr uint32_t kKindEmail = 1;
constexpr uint32_t kKindPhone = 2;

struct RawMatch {
  int32_t start;
  int32_t end;
  uint32_t kind;
  std::string url; // canonical, openable
};

// Cached from JNI_OnLoad / init_once.
JavaVM* g_vm = nullptr;
jobject g_web_url_pattern = nullptr;       // global ref to Patterns.WEB_URL
jobject g_email_pattern = nullptr;         // global ref to Patterns.EMAIL_ADDRESS
jobject g_phone_pattern = nullptr;         // global ref to Patterns.PHONE
jmethodID g_matcher_method = nullptr;      // Pattern.matcher(CharSequence)
jmethodID g_find_method = nullptr;         // Matcher.find()
jmethodID g_start_method = nullptr;        // Matcher.start()
jmethodID g_end_method = nullptr;          // Matcher.end()
jmethodID g_region_method = nullptr;       // Matcher.region(int, int)
jmethodID g_matches_method = nullptr;      // Matcher.matches()
std::once_flag g_init_once;
bool g_init_ok = false;

void clear_exception(JNIEnv* env) {
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

void init_jni_once(JNIEnv* env) {
  jclass patternsLocal = env->FindClass("android/util/Patterns");
  if (patternsLocal == nullptr || env->ExceptionCheck()) { clear_exception(env); return; }

  jfieldID webField = env->GetStaticFieldID(patternsLocal, "WEB_URL", "Ljava/util/regex/Pattern;");
  if (env->ExceptionCheck() || webField == nullptr) { clear_exception(env); env->DeleteLocalRef(patternsLocal); return; }
  jfieldID emailField = env->GetStaticFieldID(patternsLocal, "EMAIL_ADDRESS", "Ljava/util/regex/Pattern;");
  if (env->ExceptionCheck() || emailField == nullptr) { clear_exception(env); env->DeleteLocalRef(patternsLocal); return; }
  jfieldID phoneField = env->GetStaticFieldID(patternsLocal, "PHONE", "Ljava/util/regex/Pattern;");
  if (env->ExceptionCheck() || phoneField == nullptr) { clear_exception(env); env->DeleteLocalRef(patternsLocal); return; }

  jobject webLocal = env->GetStaticObjectField(patternsLocal, webField);
  if (env->ExceptionCheck() || webLocal == nullptr) { clear_exception(env); env->DeleteLocalRef(patternsLocal); return; }
  jobject emailLocal = env->GetStaticObjectField(patternsLocal, emailField);
  if (env->ExceptionCheck() || emailLocal == nullptr) { clear_exception(env); env->DeleteLocalRef(patternsLocal); env->DeleteLocalRef(webLocal); return; }
  jobject phoneLocal = env->GetStaticObjectField(patternsLocal, phoneField);
  if (env->ExceptionCheck() || phoneLocal == nullptr) {
    clear_exception(env);
    env->DeleteLocalRef(patternsLocal);
    env->DeleteLocalRef(webLocal);
    env->DeleteLocalRef(emailLocal);
    return;
  }
  env->DeleteLocalRef(patternsLocal);

  jclass patternLocal = env->FindClass("java/util/regex/Pattern");
  if (env->ExceptionCheck() || patternLocal == nullptr) { clear_exception(env); return; }
  jclass matcherLocal = env->FindClass("java/util/regex/Matcher");
  if (env->ExceptionCheck() || matcherLocal == nullptr) { clear_exception(env); env->DeleteLocalRef(patternLocal); return; }

  jmethodID matcherMethod = env->GetMethodID(patternLocal, "matcher", "(Ljava/lang/CharSequence;)Ljava/util/regex/Matcher;");
  jmethodID findMethod = env->GetMethodID(matcherLocal, "find", "()Z");
  jmethodID startMethod = env->GetMethodID(matcherLocal, "start", "()I");
  jmethodID endMethod = env->GetMethodID(matcherLocal, "end", "()I");
  jmethodID regionMethod = env->GetMethodID(matcherLocal, "region", "(II)Ljava/util/regex/Matcher;");
  jmethodID matchesMethod = env->GetMethodID(matcherLocal, "matches", "()Z");
  env->DeleteLocalRef(patternLocal);
  env->DeleteLocalRef(matcherLocal);
  if (env->ExceptionCheck() || matcherMethod == nullptr || findMethod == nullptr ||
      startMethod == nullptr || endMethod == nullptr || regionMethod == nullptr ||
      matchesMethod == nullptr) {
    clear_exception(env);
    return;
  }

  g_web_url_pattern = env->NewGlobalRef(webLocal);
  g_email_pattern = env->NewGlobalRef(emailLocal);
  g_phone_pattern = env->NewGlobalRef(phoneLocal);
  env->DeleteLocalRef(webLocal);
  env->DeleteLocalRef(emailLocal);
  env->DeleteLocalRef(phoneLocal);

  g_matcher_method = matcherMethod;
  g_find_method = findMethod;
  g_start_method = startMethod;
  g_end_method = endMethod;
  g_region_method = regionMethod;
  g_matches_method = matchesMethod;
  g_init_ok = true;
}

bool init_jni(JNIEnv* env) {
  std::call_once(g_init_once, init_jni_once, env);
  return g_init_ok;
}

// JVM strings hand us *modified* UTF-8 (CESU-8 for supplementary code points,
// NUL encoded as 0xC0 0x80) — Dart's `utf8.decode` rejects both shapes.
// Build standard UTF-8 directly from the UTF-16 source instead.
std::string utf16_to_utf8(const jchar* chars, jsize len) {
  std::string out;
  out.reserve((size_t)len);
  for (jsize i = 0; i < len; i++) {
    uint32_t cp = chars[i];
    if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
      uint32_t lo = chars[i + 1];
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
        i++;
      }
    }
    if (cp < 0x80) {
      out.push_back((char)cp);
    } else if (cp < 0x800) {
      out.push_back((char)(0xC0 | (cp >> 6)));
      out.push_back((char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
      out.push_back((char)(0xE0 | (cp >> 12)));
      out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back((char)(0x80 | (cp & 0x3F)));
    } else {
      out.push_back((char)(0xF0 | (cp >> 18)));
      out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
      out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
      out.push_back((char)(0x80 | (cp & 0x3F)));
    }
  }
  return out;
}

std::string canonical_web_url(const std::string& match) {
  // If a scheme is already present (`x://...`), pass through. Otherwise
  // prepend `http://` — Patterns.WEB_URL matches bare domains and `www.`.
  for (size_t i = 0; i < match.size(); i++) {
    char c = match[i];
    if (c == ':') {
      if (i + 2 < match.size() && match[i + 1] == '/' && match[i + 2] == '/') {
        return match;
      }
      break;
    }
    if (!(std::isalpha((unsigned char)c) || std::isdigit((unsigned char)c) ||
          c == '+' || c == '.' || c == '-')) {
      break;
    }
  }
  return std::string("http://") + match;
}

// AOSP's `Patterns.PHONE` matches any run of 3+ digits, which fires on
// short codes, ZIP codes, version strings, sport scores, etc. Require at
// least this many digits to call something a dialable number.
constexpr int kMinPhoneDigits = 7;

std::string canonical_phone(const std::string& match) {
  std::string digits;
  for (char c : match) {
    if ((c >= '0' && c <= '9') || c == '+') digits.push_back(c);
  }
  int count = 0;
  for (char c : digits) {
    if (c >= '0' && c <= '9') ++count;
  }
  if (count < kMinPhoneDigits) return {};
  return std::string("tel:") + digits;
}

// Whether `pattern` matches [start, end) of `text` whole.
bool matches_whole(JNIEnv* env, jobject pattern, jstring text, jint start, jint end) {
  jobject matcher = env->CallObjectMethod(pattern, g_matcher_method, text);
  if (env->ExceptionCheck() || matcher == nullptr) {
    clear_exception(env);
    return false;
  }
  env->DeleteLocalRef(env->CallObjectMethod(matcher, g_region_method, start, end));
  bool whole =
      !env->ExceptionCheck() && env->CallBooleanMethod(matcher, g_matches_method) && !env->ExceptionCheck();
  clear_exception(env);
  env->DeleteLocalRef(matcher);
  return whole;
}

// Whether c is path punctuation a URL may end in, or sentence punctuation or
// ')' that web_end weighs. A quote or '(' after a link belongs to the text
// around it.
bool is_path_end(jchar c) {
  return std::u16string_view(u"/?:@&=#~-+*$).,;!").find(c) != std::u16string_view::npos;
}

// Whether c belongs to a script whose text runs onto a domain with no space
// between: Han, kana, Bopomofo, Hangul, Thai, Lao, Khmer and Myanmar by block,
// and an ideograph of the supplementary planes by its high surrogate.
bool is_unspaced(jchar c) {
  return (c >= 0x0E00 && c <= 0x0EFF) || (c >= 0x1000 && c <= 0x109F) ||
         (c >= 0x1100 && c <= 0x11FF) || (c >= 0x1780 && c <= 0x17FF) ||
         (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xA960 && c <= 0xA97F) ||
         (c >= 0xAC00 && c <= 0xD7FF) || (c >= 0xD840 && c <= 0xD8BF) ||
         (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF66 && c <= 0xFFDC);
}

// The end of the web match [start, end) in the region that ends at `to`.
// Patterns.WEB_URL ends a match on a word boundary, which leaves out a path's
// trailing punctuation where text follows it and a port where unspaced letters
// follow it. The match runs on through the is_path_end punctuation after it,
// and through the digits after that where unspaced letters follow them, when
// the pattern matches the span to there whole, then ends before a trailing
// '.', ',', ';' or '!' and a trailing ')' it does not open.
jint web_end(JNIEnv* env, jobject pattern, jstring text, const jchar* chars, jint start, jint end,
             jint to) {
  jint tail = end;
  while (tail < to && is_path_end(chars[tail])) tail++;
  jint digits = tail;
  while (digits < to && chars[digits] >= u'0' && chars[digits] <= u'9') digits++;
  if (digits < to && is_unspaced(chars[digits])) tail = digits;
  if (tail > end && matches_whole(env, pattern, text, start, tail)) end = tail;
  jint unopened = 0;
  for (jint i = start; i < end; i++) {
    if (chars[i] == u')') unopened++;
    if (chars[i] == u'(') unopened--;
  }
  while (end > start) {
    jchar c = chars[end - 1];
    if (c == u')' && unopened > 0) {
      unopened--;
    } else if (!(c == u'.' || c == u',' || c == u';' || c == u'!')) {
      break;
    }
    end--;
  }
  return end;
}

// U+3000's block's punctuation and the vertical, compatibility, small,
// fullwidth and halfwidth forms of punctuation.
bool is_cjk_punctuation(jchar c) {
  return (c >= 0x3001 && c <= 0x3003) || (c >= 0x3008 && c <= 0x3011) ||
         (c >= 0x3014 && c <= 0x301F) || (c >= 0xFE10 && c <= 0xFE19) ||
         (c >= 0xFE30 && c <= 0xFE6B) || (c >= 0xFF01 && c <= 0xFF0F) ||
         (c >= 0xFF1A && c <= 0xFF20) || (c >= 0xFF3B && c <= 0xFF40) ||
         (c >= 0xFF5B && c <= 0xFF65);
}

// The glue of the host that begins the web match [start, end), which ends at
// its first change between unspaced letters and other characters inside a
// label: the '.' after the unspaced labels that begin the host, else the '.'
// before those that end it, else that change. A low surrogate goes with its
// high surrogate.
std::optional<jint> host_glue(const jchar* chars, jint start, jint end) {
  const bool leading = is_unspaced(chars[start]);
  bool unspaced = leading;
  std::optional<jint> glue;
  for (jint i = start + 1; i < end; i++) {
    const jchar c = chars[i];
    if (c == u'.' || (c >= 0xDC00 && c <= 0xDFFF)) continue;
    if (c < 0x80 && !(std::isalnum(c) || c == u'-' || c == u'_')) break;
    if (is_unspaced(c) == unspaced) continue;
    unspaced = !unspaced;
    if (chars[i - 1] != u'.') return glue.value_or(i);
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
bool has_tld(const jchar* chars, jint start, jint end) {
  jint host_end = start;
  while (host_end < end && std::u16string_view(u":/?").find(chars[host_end]) == std::u16string_view::npos) {
    host_end++;
  }
  if (host_end + 2 < end && chars[host_end] == u':' && chars[host_end + 1] == u'/' &&
      chars[host_end + 2] == u'/') {
    return true;
  }
  jint label = host_end;
  while (label > start && chars[label - 1] != u'.') label--;
  return (chars[label] >= u'0' && chars[label] <= u'9') ||
         IsTld(std::u16string(chars + label, chars + host_end));
}

bool is_path_delimiter(jchar c) {
  return std::u16string_view(u"/?#&=").find(c) != std::u16string_view::npos;
}

// Each stretch of the text between CJK punctuation is a region the pattern
// matches as a text of its own, so no link takes a mark in. Past a web link
// the region cuts at its mark, a web match is that link's path where its
// stretch holds a path delimiter before it and the pattern matches the link
// through it whole. No host runs across its glue: the web match is the part
// before the glue where the pattern matches that whole, and the search goes on
// from the glue.
void run_pattern(JNIEnv* env, jstring text, const jchar* chars, jint len, jobject pattern,
                 uint32_t kind, std::vector<RawMatch>& out) {
  jobject matcher = env->CallObjectMethod(pattern, g_matcher_method, text);
  if (env->ExceptionCheck() || matcher == nullptr) {
    clear_exception(env);
    return;
  }
  std::optional<jint> cut;
  for (jint from = 0; from <= len;) {
    jint to = from;
    while (to < len && !is_cjk_punctuation(chars[to])) to++;
    env->DeleteLocalRef(env->CallObjectMethod(matcher, g_region_method, from, to));
    if (env->ExceptionCheck()) { clear_exception(env); break; }
    while (true) {
      jboolean more = env->CallBooleanMethod(matcher, g_find_method);
      if (env->ExceptionCheck()) { clear_exception(env); break; }
      if (!more) break;

      jint start = env->CallIntMethod(matcher, g_start_method);
      if (env->ExceptionCheck()) { clear_exception(env); break; }
      jint end = env->CallIntMethod(matcher, g_end_method);
      if (env->ExceptionCheck()) { clear_exception(env); break; }
      if (kind == kKindWeb) {
        if (cut && std::any_of(chars + from, chars + start, is_path_delimiter) &&
            matches_whole(env, pattern, text, *cut, end)) continue;
        if (std::optional<jint> glue = host_glue(chars, start, end)) {
          env->DeleteLocalRef(env->CallObjectMethod(matcher, g_region_method, *glue, to));
          if (env->ExceptionCheck()) { clear_exception(env); break; }
          if (!matches_whole(env, pattern, text, start, *glue)) continue;
          end = *glue;
        }
        if (!has_tld(chars, start, end)) continue;
        if (end == to) cut = start;
        end = web_end(env, pattern, text, chars, start, end, to);
      }

      std::string group = utf16_to_utf8(chars + start, end - start);

      std::string url;
      if (kind == kKindWeb) {
        url = canonical_web_url(group);
      } else if (kind == kKindEmail) {
        url = std::string("mailto:") + group;
      } else if (kind == kKindPhone) {
        url = canonical_phone(group);
      }
      if (url.empty()) continue;
      out.push_back(RawMatch{(int32_t)start, (int32_t)end, kind, std::move(url)});
    }
    from = to + 1;
  }
  env->DeleteLocalRef(matcher);
}

void sort_and_dedup(std::vector<RawMatch>& m) {
  std::sort(m.begin(), m.end(), [](const RawMatch& a, const RawMatch& b) {
    if (a.start != b.start) return a.start < b.start;
    int32_t la = a.end - a.start;
    int32_t lb = b.end - b.start;
    if (la != lb) return la > lb;
    return a.kind > b.kind;
  });
  std::vector<RawMatch> kept;
  kept.reserve(m.size());
  int32_t lastEnd = 0;
  bool any = false;
  for (auto& it : m) {
    if (any && it.start < lastEnd) continue;
    kept.push_back(std::move(it));
    lastEnd = kept.back().end;
    any = true;
  }
  m.swap(kept);
}

uint8_t* serialize(const std::vector<RawMatch>& m, int32_t* out_size) {
  size_t total = 4;
  for (auto& it : m) total += 16 + it.url.size();
  uint8_t* buf = (uint8_t*)malloc(total);
  if (buf == nullptr) {
    if (out_size) *out_size = 0;
    return nullptr;
  }
  uint32_t count = (uint32_t)m.size();
  memcpy(buf, &count, 4);
  size_t off = 4;
  for (auto& it : m) {
    int32_t start = it.start;
    int32_t end = it.end;
    uint32_t kind = it.kind;
    uint32_t urlLen = (uint32_t)it.url.size();
    memcpy(buf + off + 0, &start, 4);
    memcpy(buf + off + 4, &end, 4);
    memcpy(buf + off + 8, &kind, 4);
    memcpy(buf + off + 12, &urlLen, 4);
    if (urlLen != 0) memcpy(buf + off + 16, it.url.data(), urlLen);
    off += 16 + urlLen;
  }
  if (out_size) *out_size = (int32_t)total;
  return buf;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_vm = vm;
  JNIEnv* env;
  if (vm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  init_jni(env);  // Best-effort; ux_match_url retries on each call if this fails.
  return JNI_VERSION_1_6;
}

extern "C" __attribute__((visibility("default")))
uint8_t* ux_match_url(const uint16_t* utf16, int32_t len, int32_t* out_size) {
  if (out_size) *out_size = 0;
  if (utf16 == nullptr || len <= 0) return nullptr;
  if (g_vm == nullptr) return nullptr;

  JNIEnv* env = nullptr;
  bool attached = false;
  jint getEnvResult = g_vm->GetEnv((void**)&env, JNI_VERSION_1_6);
  if (getEnvResult == JNI_EDETACHED) {
    if (g_vm->AttachCurrentThreadAsDaemon(&env, nullptr) != JNI_OK) {
      UX_LOGE("AttachCurrentThreadAsDaemon failed");
      return nullptr;
    }
    attached = true;
  } else if (getEnvResult != JNI_OK) {
    UX_LOGE("GetEnv failed: %d", getEnvResult);
    return nullptr;
  }

  uint8_t* buf = nullptr;
  do {
    if (!init_jni(env)) {
      clear_exception(env);
      UX_LOGE("init_jni failed");
      break;
    }

    jstring text = env->NewString((const jchar*)utf16, len);
    if (text == nullptr) {
      clear_exception(env);
      break;
    }

    std::vector<RawMatch> matches;
    matches.reserve(8);
    run_pattern(env, text, utf16, len, g_web_url_pattern, kKindWeb, matches);
    run_pattern(env, text, utf16, len, g_email_pattern, kKindEmail, matches);
    run_pattern(env, text, utf16, len, g_phone_pattern, kKindPhone, matches);
    env->DeleteLocalRef(text);

    sort_and_dedup(matches);
    if (matches.empty()) break;
    buf = serialize(matches, out_size);
  } while (false);

  if (attached) g_vm->DetachCurrentThread();
  return buf;
}

extern "C" __attribute__((visibility("default")))
void ux_free(uint8_t* buf) {
  if (buf != nullptr) free(buf);
}
