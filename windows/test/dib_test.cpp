#include <windows.h>

#include <wincodec.h>
#include <wrl/client.h>

#include <array>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <vector>

#include "../dib.h"
#include "check.h"
#include "png.h"

using Microsoft::WRL::ComPtr;
using ux::DibToPng;

namespace {

// A BITMAPINFOHEADER or a BITMAPV5HEADER, as [size] says; a V5 header carries
// [masks]: red, green, blue and alpha.
std::vector<uint8_t> Header(DWORD size, LONG width, LONG height, WORD bits, DWORD compression, DWORD colours = 0,
                            std::array<DWORD, 4> masks = {}) {
  BITMAPV5HEADER header = {};
  header.bV5Size = size;
  header.bV5Width = width;
  header.bV5Height = height;
  header.bV5Planes = 1;
  header.bV5BitCount = bits;
  header.bV5Compression = compression;
  header.bV5ClrUsed = colours;
  header.bV5RedMask = masks[0];
  header.bV5GreenMask = masks[1];
  header.bV5BlueMask = masks[2];
  header.bV5AlphaMask = masks[3];
  header.bV5CSType = LCS_sRGB;
  const auto* bytes = reinterpret_cast<const uint8_t*>(&header);
  return std::vector<uint8_t>(bytes, bytes + size);
}

void AppendBytes(std::vector<uint8_t>& dib, std::initializer_list<uint8_t> bytes) { dib.insert(dib.end(), bytes); }

void AppendWords(std::vector<uint8_t>& dib, std::initializer_list<DWORD> words) {
  for (const DWORD word : words) {
    const auto* bytes = reinterpret_cast<const uint8_t*>(&word);
    dib.insert(dib.end(), bytes, bytes + sizeof(word));
  }
}

constexpr std::array<DWORD, 4> kRgbMasks = {0x00FF0000, 0x0000FF00, 0x000000FF, 0};
constexpr std::array<DWORD, 4> kRgbaMasks = {0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000};

}  // namespace

void DibSuite() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  {
    ComPtr<IWICImagingFactory> factory;
    CHECK(SUCCEEDED(
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))));
    // Whether [dib] converts to a PNG of [width] by [height] BGRA pixels [bgra],
    // top row first.
    const auto converts = [&](const std::vector<uint8_t>& dib, UINT width, UINT height,
                              const std::vector<BYTE>& bgra) {
      std::optional<std::vector<uint8_t>> png = DibToPng(dib);
      Bitmap bitmap;
      return png && SUCCEEDED(DecodePng(factory.Get(), *png, bitmap)) && bitmap.width == width &&
             bitmap.height == height && bitmap.bgra == bgra;
    };

    // Bottom-up 24-bit rows, each padded to four bytes: white, black and grey
    // under red, green and blue.
    std::vector<uint8_t> bottom_up = Header(sizeof(BITMAPINFOHEADER), 3, 2, 24, BI_RGB);
    AppendBytes(bottom_up, {0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00});
    AppendBytes(bottom_up, {0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00});
    CHECK(converts(bottom_up, 3, 2,
                   {0x00, 0x00, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0xFF,
                    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x80, 0x80, 0x80, 0xFF}));
    bottom_up.pop_back();
    CHECK(!DibToPng(bottom_up));

    // Top-down 32-bit rows with an alpha mask.
    std::vector<uint8_t> alpha = Header(sizeof(BITMAPV5HEADER), 2, -2, 32, BI_BITFIELDS, 0, kRgbaMasks);
    const std::vector<BYTE> translucent = {0x00, 0x00, 0xFF, 0x80, 0x00, 0xFF, 0x00, 0xFF,
                                           0xFF, 0x00, 0x00, 0x40, 0xFF, 0xFF, 0xFF, 0x10};
    alpha.insert(alpha.end(), translucent.begin(), translucent.end());
    CHECK(converts(alpha, 2, 2, translucent));

    // The CF_DIBV5 that Windows synthesizes from a CF_BITMAP: no alpha mask,
    // and the masks again after the header.
    std::vector<uint8_t> synthesized = Header(sizeof(BITMAPV5HEADER), 2, 1, 32, BI_BITFIELDS, 0, kRgbMasks);
    AppendWords(synthesized, {kRgbMasks[0], kRgbMasks[1], kRgbMasks[2]});
    AppendBytes(synthesized, {0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x80});
    CHECK(converts(synthesized, 2, 1, {0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF}));

    // 4-bit indices into a table of two colours, blue and yellow.
    std::vector<uint8_t> indexed = Header(sizeof(BITMAPINFOHEADER), 3, 1, 4, BI_RGB, 2);
    AppendBytes(indexed, {0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00});
    AppendBytes(indexed, {0x10, 0x10, 0x00, 0x00});
    CHECK(converts(indexed, 3, 1, {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0xFF}));

    // 16-bit 5-6-5 pixels, their masks after the header: red, and the middle
    // of each channel.
    std::vector<uint8_t> short_channels = Header(sizeof(BITMAPINFOHEADER), 2, 1, 16, BI_BITFIELDS);
    AppendWords(short_channels, {DWORD{0xF800}, DWORD{0x07E0}, DWORD{0x001F}});
    AppendBytes(short_channels, {0x00, 0xF8, 0x10, 0x84});
    CHECK(converts(short_channels, 2, 1, {0x00, 0x00, 0xFF, 0xFF, 132, 130, 132, 0xFF}));
  }
  CoUninitialize();
}
