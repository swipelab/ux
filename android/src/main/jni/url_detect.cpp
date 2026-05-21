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
#include <string>
#include <vector>

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
jmethodID g_group_method = nullptr;        // Matcher.group()
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
  jmethodID groupMethod = env->GetMethodID(matcherLocal, "group", "()Ljava/lang/String;");
  env->DeleteLocalRef(patternLocal);
  env->DeleteLocalRef(matcherLocal);
  if (env->ExceptionCheck() || matcherMethod == nullptr || findMethod == nullptr ||
      startMethod == nullptr || endMethod == nullptr || groupMethod == nullptr) {
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
  g_group_method = groupMethod;
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

std::string jstring_to_utf8(JNIEnv* env, jstring s) {
  if (s == nullptr) return {};
  const jchar* chars = env->GetStringChars(s, nullptr);
  if (chars == nullptr) return {};
  jsize len = env->GetStringLength(s);
  std::string out = utf16_to_utf8(chars, len);
  env->ReleaseStringChars(s, chars);
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

void run_pattern(JNIEnv* env, jstring text, jobject pattern, uint32_t kind,
                 std::vector<RawMatch>& out) {
  jobject matcher = env->CallObjectMethod(pattern, g_matcher_method, text);
  if (env->ExceptionCheck() || matcher == nullptr) {
    clear_exception(env);
    return;
  }
  while (true) {
    jboolean more = env->CallBooleanMethod(matcher, g_find_method);
    if (env->ExceptionCheck()) { clear_exception(env); break; }
    if (!more) break;

    jint start = env->CallIntMethod(matcher, g_start_method);
    if (env->ExceptionCheck()) { clear_exception(env); break; }
    jint end = env->CallIntMethod(matcher, g_end_method);
    if (env->ExceptionCheck()) { clear_exception(env); break; }
    jobject groupObj = env->CallObjectMethod(matcher, g_group_method);
    if (env->ExceptionCheck()) {
      clear_exception(env);
      if (groupObj != nullptr) env->DeleteLocalRef(groupObj);
      break;
    }
    if (groupObj == nullptr) continue;

    std::string group = jstring_to_utf8(env, (jstring)groupObj);
    env->DeleteLocalRef(groupObj);

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
    run_pattern(env, text, g_web_url_pattern, kKindWeb, matches);
    run_pattern(env, text, g_email_pattern, kKindEmail, matches);
    run_pattern(env, text, g_phone_pattern, kKindPhone, matches);
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
