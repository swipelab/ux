// XUrl.match's phones on Android, over dart:ffi:
//
//   uint8_t* ux_match_phones(const uint16_t* utf16, int32_t len, int32_t* out_size);
//   void     ux_free(uint8_t* buf);
//
// The buffer, of out_size bytes in the platform's byte order, holds a u32
// count and then, for each match of android.util.Patterns.PHONE, its i32
// start, i32 end and u32 length and that many UTF-16 units of its text.

#include <jni.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <vector>

namespace {

JavaVM* g_vm = nullptr;
jobject g_phone = nullptr;      // Patterns.PHONE
jmethodID g_matcher = nullptr;  // Pattern.matcher(CharSequence)
jmethodID g_find = nullptr;     // Matcher.find()
jmethodID g_start = nullptr;    // Matcher.start()
jmethodID g_end = nullptr;      // Matcher.end()

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_vm = vm;
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  jclass patterns = env->FindClass("android/util/Patterns");
  jobject phone = env->GetStaticObjectField(
      patterns, env->GetStaticFieldID(patterns, "PHONE", "Ljava/util/regex/Pattern;"));
  g_phone = env->NewGlobalRef(phone);
  jclass pattern = env->FindClass("java/util/regex/Pattern");
  g_matcher = env->GetMethodID(pattern, "matcher", "(Ljava/lang/CharSequence;)Ljava/util/regex/Matcher;");
  jclass matcher = env->FindClass("java/util/regex/Matcher");
  g_find = env->GetMethodID(matcher, "find", "()Z");
  g_start = env->GetMethodID(matcher, "start", "()I");
  g_end = env->GetMethodID(matcher, "end", "()I");
  env->DeleteLocalRef(matcher);
  env->DeleteLocalRef(pattern);
  env->DeleteLocalRef(phone);
  env->DeleteLocalRef(patterns);
  return JNI_VERSION_1_6;
}

extern "C" __attribute__((visibility("default")))
uint8_t* ux_match_phones(const uint16_t* utf16, int32_t len, int32_t* out_size) {
  JNIEnv* env = nullptr;
  const bool attach = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_EDETACHED;
  if (attach) g_vm->AttachCurrentThreadAsDaemon(&env, nullptr);
  jstring text = env->NewString(reinterpret_cast<const jchar*>(utf16), len);
  jobject matcher = env->CallObjectMethod(g_phone, g_matcher, text);
  std::vector<std::pair<int32_t, int32_t>> phones;
  while (env->CallBooleanMethod(matcher, g_find)) {
    phones.emplace_back(env->CallIntMethod(matcher, g_start), env->CallIntMethod(matcher, g_end));
  }
  env->DeleteLocalRef(matcher);
  env->DeleteLocalRef(text);
  if (attach) g_vm->DetachCurrentThread();

  size_t size = 4;
  for (auto [start, end] : phones) size += 12 + 2 * static_cast<size_t>(end - start);
  auto* buf = static_cast<uint8_t*>(malloc(size));
  const auto count = static_cast<uint32_t>(phones.size());
  memcpy(buf, &count, 4);
  size_t at = 4;
  for (auto [start, end] : phones) {
    const auto length = static_cast<uint32_t>(end - start);
    memcpy(buf + at, &start, 4);
    memcpy(buf + at + 4, &end, 4);
    memcpy(buf + at + 8, &length, 4);
    memcpy(buf + at + 12, utf16 + start, 2 * static_cast<size_t>(length));
    at += 12 + 2 * static_cast<size_t>(length);
  }
  *out_size = static_cast<int32_t>(size);
  return buf;
}

extern "C" __attribute__((visibility("default")))
void ux_free(uint8_t* buf) {
  free(buf);
}
