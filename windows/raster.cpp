#include "raster.h"

#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <thread>

namespace ux {

namespace {

using Microsoft::WRL::ComPtr;

// Maps a [width]×[height] frame's pixels to the frame turned [turns] quarter
// turns clockwise.
Affine Turn(UINT width, UINT height, int turns) {
  const double w = width;
  const double h = height;
  switch (((turns % 4) + 4) % 4) {
    case 1:
      return {0, -1, h, 1, 0, 0};
    case 2:
      return {-1, 0, w, 0, -1, h};
    case 3:
      return {0, 1, 0, -1, 0, w};
    default:
      return {};
  }
}

// Composites the premultiplied [source] pixel over [pixel].
void Over(const uint8_t* source, uint8_t* pixel) {
  const uint32_t alpha = source[3];
  if (alpha == 255) {
    std::copy(source, source + 4, pixel);
    return;
  }
  if (alpha == 0) return;
  for (int c = 0; c < 4; c++) {
    pixel[c] = static_cast<uint8_t>(std::min<uint32_t>(255, source[c] + (pixel[c] * (255 - alpha) + 127) / 255));
  }
}

// [value] as -1, 0 or 1, when it is one of them.
std::optional<int> UnitStep(double value) {
  const double rounded = std::round(value);
  if (std::abs(value - rounded) > 1e-9 || std::abs(rounded) > 1) return std::nullopt;
  return static_cast<int>(rounded);
}

// A map from canvas to source pixels that carries each canvas pixel's centre
// onto a source pixel's centre: canvas pixel (i, j) shows source pixel
// (x0 + a i + b j, y0 + d i + e j).
struct ExactMap {
  int a;
  int b;
  int d;
  int e;
  int64_t x0;
  int64_t y0;
};

std::optional<ExactMap> Exact(const Affine& map) {
  const std::optional<int> a = UnitStep(map.a);
  const std::optional<int> b = UnitStep(map.b);
  const std::optional<int> d = UnitStep(map.d);
  const std::optional<int> e = UnitStep(map.e);
  if (!a || !b || !d || !e || std::abs(*a * *e - *b * *d) != 1) return std::nullopt;
  const double x = (map.a + map.b) / 2 + map.tx - 0.5;
  const double y = (map.d + map.e) / 2 + map.ty - 0.5;
  if (std::abs(x - std::round(x)) > 1e-6 || std::abs(y - std::round(y)) > 1e-6) return std::nullopt;
  return ExactMap{*a, *b, *d, *e, std::llround(x), std::llround(y)};
}

void DrawRows(const Image& source, const ExactMap& map, Image& canvas, UINT first, UINT last) {
  for (int64_t j = first; j < last; j++) {
    uint8_t* row = canvas.pixels.data() + j * canvas.width * 4;
    for (int64_t i = 0; i < canvas.width; i++) {
      const int64_t sx = map.x0 + map.a * i + map.b * j;
      const int64_t sy = map.y0 + map.d * i + map.e * j;
      if (sx < 0 || sy < 0 || sx >= source.width || sy >= source.height) continue;
      Over(source.pixels.data() + (sy * source.width + sx) * 4, row + i * 4);
    }
  }
}

// Adds [source]'s bilinear sample at ([x], [y]), in pixel-index space and at
// least -0.5 each, to [sum], in 1/65536ths.
void AddSample(const Image& source, double x, double y, uint32_t sum[4]) {
  const int fx = static_cast<int>(x + 1) - 1;
  const int fy = static_cast<int>(y + 1) - 1;
  const auto wx = static_cast<uint32_t>((x - fx) * 256);
  const auto wy = static_cast<uint32_t>((y - fy) * 256);
  const int x0 = std::max(fx, 0);
  const int x1 = std::min(fx + 1, static_cast<int>(source.width) - 1);
  const int y0 = std::max(fy, 0);
  const int y1 = std::min(fy + 1, static_cast<int>(source.height) - 1);
  const uint8_t* p00 = source.pixels.data() + (static_cast<size_t>(y0) * source.width + x0) * 4;
  const uint8_t* p01 = source.pixels.data() + (static_cast<size_t>(y0) * source.width + x1) * 4;
  const uint8_t* p10 = source.pixels.data() + (static_cast<size_t>(y1) * source.width + x0) * 4;
  const uint8_t* p11 = source.pixels.data() + (static_cast<size_t>(y1) * source.width + x1) * 4;
  for (int c = 0; c < 4; c++) {
    sum[c] += (p00[c] * (256 - wx) + p01[c] * wx) * (256 - wy) + (p10[c] * (256 - wx) + p11[c] * wx) * wy;
  }
}

// How many samples per axis a canvas pixel averages through [map], from canvas
// to source pixels: as many as the source pixels it spans.
int Samples(const Affine& map) {
  const double span = std::max(std::hypot(map.a, map.d), std::hypot(map.b, map.e));
  return std::clamp(static_cast<int>(std::ceil(span - 1e-6)), 1, 8);
}

// Draws through [map], from canvas to source pixels, averaging n×n bilinear
// samples per canvas pixel.
void DrawRows(const Image& source, const Affine& map, int n, Image& canvas, UINT first, UINT last) {
  const uint32_t total = 65536u * n * n;
  const double width = source.width;
  const double height = source.height;
  for (UINT j = first; j < last; j++) {
    uint8_t* row = canvas.pixels.data() + static_cast<size_t>(j) * canvas.width * 4;
    for (UINT i = 0; i < canvas.width; i++) {
      uint32_t sum[4] = {};
      for (int sj = 0; sj < n; sj++) {
        const double cy = j + (sj + 0.5) / n;
        for (int si = 0; si < n; si++) {
          const double cx = i + (si + 0.5) / n;
          const double x = map.a * cx + map.b * cy + map.tx;
          const double y = map.d * cx + map.e * cy + map.ty;
          if (x < 0 || y < 0 || x >= width || y >= height) continue;
          AddSample(source, x - 0.5, y - 0.5, sum);
        }
      }
      if (sum[3] == 0) continue;
      uint8_t color[4];
      for (int c = 0; c < 4; c++) color[c] = static_cast<uint8_t>((sum[c] + total / 2) / total);
      Over(color, row + i * 4);
    }
  }
}

// Runs [draw] over bands of [canvas]'s rows, on as many threads as the
// processor has, up to 8, once the canvas holds 64K pixels.
void InBands(const Image& canvas, const std::function<void(UINT, UINT)>& draw) {
  const UINT bands = static_cast<size_t>(canvas.width) * canvas.height < 65536
                         ? 1
                         : std::clamp(std::thread::hardware_concurrency(), 1u, 8u);
  std::vector<std::thread> threads;
  for (UINT band = 1; band < bands; band++) {
    threads.emplace_back(draw, canvas.height * band / bands, canvas.height * (band + 1) / bands);
  }
  draw(0, canvas.height / bands);
  for (std::thread& thread : threads) thread.join();
}

HRESULT Factory(ComPtr<IWICImagingFactory>& factory) {
  return CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
}

}  // namespace

void Image::Reset(UINT w, UINT h, uint32_t bgra) {
  width = w;
  height = h;
  const uint8_t pixel[4] = {static_cast<uint8_t>(bgra), static_cast<uint8_t>(bgra >> 8),
                            static_cast<uint8_t>(bgra >> 16), static_cast<uint8_t>(bgra >> 24)};
  pixels.resize(static_cast<size_t>(w) * h * 4);
  for (size_t i = 0; i < pixels.size(); i += 4) std::copy(pixel, pixel + 4, pixels.data() + i);
}

Affine Affine::Scale(double sx, double sy) { return {sx, 0, 0, 0, sy, 0}; }

Affine Affine::Then(const Affine& next) const {
  return {
      next.a * a + next.b * d,  next.a * b + next.b * e,  next.a * tx + next.b * ty + next.tx,
      next.d * a + next.e * d,  next.d * b + next.e * e,  next.d * tx + next.e * ty + next.ty,
  };
}

std::optional<Affine> Affine::Inverse() const {
  const double det = a * e - b * d;
  if (std::abs(det) < 1e-12) return std::nullopt;
  Affine inverse{e / det, -b / det, 0, -d / det, a / det, 0};
  inverse.tx = -(inverse.a * tx + inverse.b * ty);
  inverse.ty = -(inverse.d * tx + inverse.e * ty);
  return inverse;
}

std::pair<UINT, UINT> Turned(UINT width, UINT height, int turns) {
  return turns % 2 == 0 ? std::make_pair(width, height) : std::make_pair(height, width);
}

void Draw(const Image& source, int turns, const Affine& affine, Image& canvas) {
  const std::optional<Affine> map = Turn(source.width, source.height, turns).Then(affine).Inverse();
  if (!map) return;
  const std::optional<ExactMap> exact = Exact(*map);
  const int n = Samples(*map);
  InBands(canvas, [&](UINT first, UINT last) {
    if (exact) {
      DrawRows(source, *exact, canvas, first, last);
    } else {
      DrawRows(source, *map, n, canvas, first, last);
    }
  });
}

void ToNv12(const Image& image, YuvMatrix matrix, uint8_t* nv12, size_t stride) {
  // Y = 16 + 219 (Kr R + Kg G + Kb B), Cb = 128 + 224 (B - Y') / (2 - 2 Kb) and
  // Cr = 128 + 224 (R - Y') / (2 - 2 Kr), on 8-bit R, G and B, in 1/65536ths.
  struct Coefficients {
    int y[3];
    int cb[3];
    int cr[3];
  };
  static constexpr Coefficients kBt601{{16829, 33039, 6416}, {-9714, -19070, 28784}, {28784, -24103, -4681}};
  static constexpr Coefficients kBt709{{11966, 40254, 4064}, {-6596, -22189, 28785}, {28784, -26145, -2639}};
  const Coefficients& k = matrix == YuvMatrix::kBt709 ? kBt709 : kBt601;
  uint8_t* chroma_plane = nv12 + image.height * stride;
  for (UINT y = 0; y < image.height; y += 2) {
    const uint8_t* rows[2] = {image.pixels.data() + static_cast<size_t>(y) * image.width * 4,
                              image.pixels.data() + static_cast<size_t>(y + 1) * image.width * 4};
    uint8_t* luma[2] = {nv12 + y * stride, nv12 + (y + 1) * stride};
    uint8_t* chroma = chroma_plane + y / 2 * stride;
    for (UINT x = 0; x < image.width; x += 2) {
      int r = 0;
      int g = 0;
      int b = 0;
      for (int row = 0; row < 2; row++) {
        for (UINT column = x; column < x + 2; column++) {
          const uint8_t* pixel = rows[row] + column * 4;
          luma[row][column] =
              static_cast<uint8_t>(16 + ((k.y[0] * pixel[2] + k.y[1] * pixel[1] + k.y[2] * pixel[0] + 32768) >> 16));
          r += pixel[2];
          g += pixel[1];
          b += pixel[0];
        }
      }
      // Each chroma pair averages its 2×2 block.
      chroma[x] = static_cast<uint8_t>(128 + ((k.cb[0] * r + k.cb[1] * g + k.cb[2] * b + (1 << 17)) >> 18));
      chroma[x + 1] = static_cast<uint8_t>(128 + ((k.cr[0] * r + k.cr[1] * g + k.cr[2] * b + (1 << 17)) >> 18));
    }
  }
}

HRESULT EncodePng(const Image& image, std::vector<uint8_t>& png) {
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = Factory(factory);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmap> bitmap;
  hr = factory->CreateBitmapFromMemory(image.width, image.height, GUID_WICPixelFormat32bppPBGRA, image.width * 4,
                                       static_cast<UINT>(image.pixels.size()), const_cast<BYTE*>(image.pixels.data()),
                                       &bitmap);
  if (FAILED(hr)) return hr;
  ComPtr<IWICFormatConverter> straight;
  hr = factory->CreateFormatConverter(&straight);
  if (FAILED(hr)) return hr;
  hr = straight->Initialize(bitmap.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                            WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return hr;
  return EncodePng(factory.Get(), straight.Get(), png);
}

HRESULT EncodePng(IWICImagingFactory* factory, IWICBitmapSource* source, std::vector<uint8_t>& png) {
  UINT width = 0;
  UINT height = 0;
  HRESULT hr = source->GetSize(&width, &height);
  if (FAILED(hr)) return hr;
  ComPtr<IStream> stream;
  hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (FAILED(hr)) return hr;
  hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapFrameEncode> frame;
  hr = encoder->CreateNewFrame(&frame, nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->Initialize(nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->SetSize(width, height);
  if (FAILED(hr)) return hr;
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return hr;
  if (format != GUID_WICPixelFormat32bppBGRA) return WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT;
  hr = frame->WriteSource(source, nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->Commit();
  if (FAILED(hr)) return hr;
  hr = encoder->Commit();
  if (FAILED(hr)) return hr;
  STATSTG stat;
  hr = stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr)) return hr;
  HGLOBAL global = nullptr;
  hr = GetHGlobalFromStream(stream.Get(), &global);
  if (FAILED(hr)) return hr;
  const auto* bytes = static_cast<const uint8_t*>(GlobalLock(global));
  if (bytes == nullptr) return HRESULT_FROM_WIN32(GetLastError());
  png.assign(bytes, bytes + stat.cbSize.QuadPart);
  GlobalUnlock(global);
  return S_OK;
}

HRESULT DecodeImage(const std::wstring& path, Image& image) {
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = Factory(factory);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                          &decoder);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) return hr;
  ComPtr<IWICFormatConverter> premultiplied;
  hr = factory->CreateFormatConverter(&premultiplied);
  if (FAILED(hr)) return hr;
  hr = premultiplied->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                 WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return hr;
  UINT width = 0;
  UINT height = 0;
  hr = premultiplied->GetSize(&width, &height);
  if (FAILED(hr)) return hr;
  image.width = width;
  image.height = height;
  image.pixels.resize(static_cast<size_t>(width) * height * 4);
  return premultiplied->CopyPixels(nullptr, width * 4, static_cast<UINT>(image.pixels.size()), image.pixels.data());
}

}  // namespace ux
