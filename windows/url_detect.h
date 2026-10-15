#ifndef UX_URL_DETECT_H_
#define UX_URL_DETECT_H_

#include <cstdint>

// XUrl.match's native detector, under android/src/main/jni/url_detect.cpp's
// contract: the web, email and phone links of `len` UTF-16 code units, in a
// buffer that ux_free releases, or null with *out_size 0 when there are none.
//
//   u32 count
//   count * { i32 start, i32 end, u32 kind, u32 url_len, u8[url_len] url_utf8 }
//
// little-endian; offsets in UTF-16 code units; kind 0 web, 1 email, 2 phone.
// Safe to call from several threads at once.
extern "C" __declspec(dllexport) uint8_t* ux_match_url(const uint16_t* utf16, int32_t len, int32_t* out_size);

extern "C" __declspec(dllexport) void ux_free(uint8_t* buf);

#endif  // UX_URL_DETECT_H_
