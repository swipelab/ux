#include "dib.h"

#include <windows.h>

#include <intrin.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <climits>
#include <cstring>

#include "com_scope.h"
#include "raster.h"

namespace ux {

namespace {

using Microsoft::WRL::ComPtr;

template <typename T>
T Load(const uint8_t* at) {
  T value;
  std::memcpy(&value, at, sizeof(T));
  return value;
}

// The bits of a pixel that one channel's mask selects.
struct Channel {
  uint32_t mask;
  unsigned long shift;
  // The channel's largest value.
  uint32_t max;

  // The channel of [pixel], scaled to eight bits.
  uint8_t Of(uint32_t pixel) const {
    if (max == 0) return 0;
    return static_cast<uint8_t>((uint64_t{(pixel & mask) >> shift} * 255 + max / 2) / max);
  }
};

Channel ChannelOf(uint32_t mask) {
  unsigned long shift = 0;
  if (!_BitScanForward(&shift, mask)) return {0, 0, 0};
  return {mask, shift, mask >> shift};
}

// An image as 32-bit BGRA with straight alpha, its top row first.
struct Bgra {
  UINT width;
  UINT height;
  std::vector<BYTE> pixels;
};

std::optional<Bgra> ReadDib(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return std::nullopt;
  const auto header = Load<BITMAPINFOHEADER>(dib.data());
  const bool v4 = header.biSize == sizeof(BITMAPV4HEADER) || header.biSize == sizeof(BITMAPV5HEADER);
  if ((header.biSize != sizeof(BITMAPINFOHEADER) && !v4) || dib.size() < header.biSize) return std::nullopt;
  const WORD bits = header.biBitCount;
  const bool bitfields = header.biCompression == BI_BITFIELDS;
  if (bits != 1 && bits != 4 && bits != 8 && bits != 16 && bits != 24 && bits != 32) return std::nullopt;
  if (header.biCompression != BI_RGB && !(bitfields && (bits == 16 || bits == 32))) return std::nullopt;
  if (header.biWidth <= 0 || header.biHeight == 0 || header.biHeight == LONG_MIN) return std::nullopt;
  const auto width = static_cast<UINT>(header.biWidth);
  const bool top_down = header.biHeight < 0;
  const auto height = static_cast<UINT>(top_down ? -header.biHeight : header.biHeight);
  // WIC takes the BGRA buffer's size as a UINT.
  if (uint64_t{width} * height > UINT_MAX / 4) return std::nullopt;

  // Red, green, blue and alpha.
  uint32_t masks[4] = {};
  if (bits == 16) {
    masks[0] = 0x7C00;
    masks[1] = 0x03E0;
    masks[2] = 0x001F;
  } else if (bits >= 24) {
    masks[0] = 0xFF0000;
    masks[1] = 0x00FF00;
    masks[2] = 0x0000FF;
  }
  size_t at = header.biSize;
  if (bitfields && v4) {
    const auto v4_header = Load<BITMAPV4HEADER>(dib.data());
    masks[0] = v4_header.bV4RedMask;
    masks[1] = v4_header.bV4GreenMask;
    masks[2] = v4_header.bV4BlueMask;
  } else if (bitfields) {
    if (dib.size() - at < 3 * sizeof(uint32_t)) return std::nullopt;
    std::memcpy(masks, dib.data() + at, 3 * sizeof(uint32_t));
    at += 3 * sizeof(uint32_t);
  }
  if (v4 && (bits == 16 || bits == 32)) masks[3] = Load<BITMAPV4HEADER>(dib.data()).bV4AlphaMask;

  const uint64_t stride = (uint64_t{width} * bits + 31) / 32 * 4;
  const uint64_t rows = stride * height;
  const uint32_t colours = header.biClrUsed != 0 ? header.biClrUsed : bits <= 8 ? 1u << bits : 0;
  if (bits <= 8 && colours > 1u << bits) return std::nullopt;
  const uint64_t table_size = uint64_t{colours} * sizeof(RGBQUAD);
  // The CF_DIBV5 that Windows synthesizes repeats the masks after the header.
  if (bitfields && v4 && dib.size() - at >= 3 * sizeof(uint32_t) + table_size + rows &&
      std::memcmp(dib.data() + at, masks, 3 * sizeof(uint32_t)) == 0) {
    at += 3 * sizeof(uint32_t);
  }
  const size_t table = at;
  if (dib.size() - table < table_size + rows) return std::nullopt;
  const uint8_t* pixels = dib.data() + table + table_size;

  const Channel red = ChannelOf(masks[0]);
  const Channel green = ChannelOf(masks[1]);
  const Channel blue = ChannelOf(masks[2]);
  const Channel alpha = ChannelOf(masks[3]);
  Bgra image{width, height, std::vector<BYTE>(size_t{width} * height * 4)};
  BYTE* out = image.pixels.data();
  for (UINT y = 0; y < height; y++) {
    const uint8_t* row = pixels + stride * (top_down ? y : height - 1 - y);
    for (UINT x = 0; x < width; x++, out += 4) {
      if (bits <= 8) {
        const uint64_t bit = uint64_t{x} * bits;
        const uint32_t index = (row[bit / 8] >> (8 - bits - bit % 8)) & ((1u << bits) - 1);
        if (index >= colours) return std::nullopt;
        const auto colour = Load<RGBQUAD>(dib.data() + table + index * sizeof(RGBQUAD));
        out[0] = colour.rgbBlue;
        out[1] = colour.rgbGreen;
        out[2] = colour.rgbRed;
        out[3] = 0xFF;
        continue;
      }
      uint32_t pixel;
      if (bits == 16) {
        pixel = Load<uint16_t>(row + x * 2);
      } else if (bits == 24) {
        pixel = row[x * 3] | row[x * 3 + 1] << 8 | row[x * 3 + 2] << 16;
      } else {
        pixel = Load<uint32_t>(row + x * 4);
      }
      out[0] = blue.Of(pixel);
      out[1] = green.Of(pixel);
      out[2] = red.Of(pixel);
      out[3] = alpha.mask != 0 ? alpha.Of(pixel) : 0xFF;
    }
  }
  return image;
}

}  // namespace

std::optional<std::vector<uint8_t>> DibToPng(const std::vector<uint8_t>& dib) {
  std::optional<Bgra> image = ReadDib(dib);
  if (!image) return std::nullopt;
  ComScope com;
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmap> bitmap;
  std::vector<uint8_t> png;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      FAILED(factory->CreateBitmapFromMemory(image->width, image->height, GUID_WICPixelFormat32bppBGRA,
                                             image->width * 4, static_cast<UINT>(image->pixels.size()),
                                             image->pixels.data(), &bitmap)) ||
      FAILED(EncodePng(factory.Get(), bitmap.Get(), png))) {
    return std::nullopt;
  }
  return png;
}

}  // namespace ux
