#include "text.h"

#include <windows.h>

namespace ux {

std::optional<std::wstring> Utf16(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()),
                                       nullptr, 0);
  if (size == 0) return std::nullopt;
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), wide.data(), size);
  return wide;
}

std::optional<std::string> Utf8(const std::wstring& utf16) {
  if (utf16.empty()) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, utf16.data(), static_cast<int>(utf16.size()),
                                       nullptr, 0, nullptr, nullptr);
  if (size == 0) return std::nullopt;
  std::string narrow(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, utf16.data(), static_cast<int>(utf16.size()), narrow.data(), size,
                      nullptr, nullptr);
  return narrow;
}

}  // namespace ux
