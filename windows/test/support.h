#ifndef UX_TEST_SUPPORT_H_
#define UX_TEST_SUPPORT_H_

#include <windows.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "../raster.h"

// A pixel's B, G, R and A.
using Pixel = std::array<int, 4>;

inline Pixel At(const ux::Image& image, UINT x, UINT y) {
  const uint8_t* p = image.pixels.data() + (static_cast<size_t>(y) * image.width + x) * 4;
  return {p[0], p[1], p[2], p[3]};
}

// [bgra] as a pixel, B in its lowest byte.
inline Pixel Of(uint32_t bgra) {
  return {static_cast<int>(bgra & 0xFF), static_cast<int>((bgra >> 8) & 0xFF), static_cast<int>((bgra >> 16) & 0xFF),
          static_cast<int>(bgra >> 24)};
}

inline bool Near(const Pixel& actual, const Pixel& expected, int tolerance) {
  for (int c = 0; c < 4; c++) {
    if (std::abs(actual[c] - expected[c]) > tolerance) return false;
  }
  return true;
}

// [name] in the temporary directory.
inline std::wstring TempPath(const std::wstring& name) {
  wchar_t directory[MAX_PATH];
  GetTempPathW(MAX_PATH, directory);
  return directory + name;
}

inline bool WriteBytes(const std::wstring& path, const std::vector<uint8_t>& bytes) {
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const BOOL wrote = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr);
  CloseHandle(file);
  return wrote && written == bytes.size();
}

#endif  // UX_TEST_SUPPORT_H_
