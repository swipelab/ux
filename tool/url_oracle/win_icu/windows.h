// Stands in for <windows.h> where windows/url_detect.cpp builds against ICU on
// macOS: its one call, the UTF-16 to UTF-8 conversion, through ICU.
#ifndef UX_ORACLE_WINDOWS_H_
#define UX_ORACLE_WINDOWS_H_

#include <unicode/ustring.h>

#define CP_UTF8 65001

// wchar_t is 32 bits here, so `wide` holds the UTF-16 code units the caller
// casts to it. An unpaired surrogate becomes U+FFFD, as on Windows.
inline int WideCharToMultiByte(unsigned, unsigned long, const wchar_t* wide, int len, char* out, int size, const char*,
                               int*) {
  UErrorCode status = U_ZERO_ERROR;
  int32_t needed = 0;
  u_strToUTF8WithSub(out, size, &needed, reinterpret_cast<const UChar*>(wide), len, 0xFFFD, nullptr, &status);
  return needed;
}

#endif  // UX_ORACLE_WINDOWS_H_
