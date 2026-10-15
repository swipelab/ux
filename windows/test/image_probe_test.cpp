#include <windows.h>

#include <wincodec.h>
#include <wrl/client.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "../image_probe.h"
#include "check.h"
#include "png.h"

using Microsoft::WRL::ComPtr;
using ux::ImageThumbnail;
using ux::ProbeSize;
using ux::ProbeThumbnail;
using ux::UprightSize;

namespace {

// The upright image's quadrants: top-left, top-right, bottom-left and
// bottom-right.
constexpr Rgb kQuadrants[] = {{0xCC, 0x33, 0x33}, {0x33, 0xCC, 0x33}, {0x33, 0x33, 0xCC}, {0xCC, 0xCC, 0x33}};

UprightSize UprightOf(USHORT orientation, UINT width, UINT height) {
  return orientation >= 5 ? UprightSize{height, width} : UprightSize{width, height};
}

// Where the pixel at ([x], [y]) of a [width] by [height] image stored with EXIF
// [orientation] lands once the image is upright.
std::pair<UINT, UINT> Landing(USHORT orientation, UINT width, UINT height, UINT x, UINT y) {
  switch (orientation) {
    case 2:
      return {width - 1 - x, y};
    case 3:
      return {width - 1 - x, height - 1 - y};
    case 4:
      return {x, height - 1 - y};
    case 5:
      return {y, x};
    case 6:
      return {height - 1 - y, x};
    case 7:
      return {height - 1 - y, width - 1 - x};
    case 8:
      return {y, width - 1 - x};
    default:
      return {x, y};
  }
}

// Writes a [width] by [height] JPEG stored with EXIF [orientation], which shows
// kQuadrants upright.
HRESULT WriteJpeg(IWICImagingFactory* factory, const std::filesystem::path& path, UINT width, UINT height,
                  USHORT orientation) {
  const UprightSize upright = UprightOf(orientation, width, height);
  const UINT stride = width * 3;
  std::vector<BYTE> pixels(static_cast<size_t>(stride) * height);
  for (UINT y = 0; y < height; y++) {
    for (UINT x = 0; x < width; x++) {
      const auto [u, v] = Landing(orientation, width, height, x, y);
      const Rgb& rgb = kQuadrants[(v >= upright.height / 2 ? 2 : 0) + (u >= upright.width / 2 ? 1 : 0)];
      BYTE* bgr = &pixels[static_cast<size_t>(y) * stride + x * 3];
      bgr[0] = rgb[2];
      bgr[1] = rgb[1];
      bgr[2] = rgb[0];
    }
  }
  ComPtr<IWICStream> stream;
  HRESULT hr = factory->CreateStream(&stream);
  if (FAILED(hr)) return hr;
  hr = stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE);
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder);
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
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return hr;
  ComPtr<IWICMetadataQueryWriter> metadata;
  hr = frame->GetMetadataQueryWriter(&metadata);
  if (FAILED(hr)) return hr;
  PROPVARIANT value;
  PropVariantInit(&value);
  value.vt = VT_UI2;
  value.uiVal = orientation;
  hr = metadata->SetMetadataByName(L"/app1/ifd/{ushort=274}", &value);
  if (FAILED(hr)) return hr;
  hr = frame->WritePixels(height, stride, static_cast<UINT>(pixels.size()), pixels.data());
  if (FAILED(hr)) return hr;
  hr = frame->Commit();
  if (FAILED(hr)) return hr;
  return encoder->Commit();
}

// Whether [bitmap] shows kQuadrants, upright.
bool ShowsQuadrants(const Bitmap& bitmap) {
  const UINT w = bitmap.width;
  const UINT h = bitmap.height;
  const std::pair<UINT, UINT> centres[] = {{w / 4, h / 4}, {3 * w / 4, h / 4}, {w / 4, 3 * h / 4}, {3 * w / 4, 3 * h / 4}};
  for (size_t i = 0; i < 4; i++) {
    const Rgb pixel = bitmap.At(centres[i].first, centres[i].second);
    for (size_t c = 0; c < 3; c++) {
      if (std::abs(pixel[c] - kQuadrants[i][c]) > 24) return false;
    }
  }
  return true;
}

bool Equal(const UprightSize& a, const UprightSize& b) { return a.width == b.width && a.height == b.height; }

}  // namespace

void ImageProbeSuite() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  {
    ComPtr<IWICImagingFactory> factory;
    CHECK(SUCCEEDED(
        CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))));
    std::error_code error;
    const std::filesystem::path dir = std::filesystem::temp_directory_path(error) / L"ux_test_image_probe";
    std::filesystem::create_directories(dir, error);

    for (USHORT orientation = 1; orientation <= 8; orientation++) {
      const std::filesystem::path path = dir / (L"orientation_" + std::to_wstring(orientation) + L".jpg");
      CHECK(SUCCEEDED(WriteJpeg(factory.Get(), path, 192, 128, orientation)));
      const UprightSize upright = UprightOf(orientation, 192, 128);

      const std::optional<UprightSize> size = ProbeSize(path.wstring());
      CHECK(size && Equal(*size, upright));

      std::optional<ImageThumbnail> thumbnail = ProbeThumbnail(path.wstring(), 96);
      CHECK(thumbnail && Equal(thumbnail->source, upright) && Equal(thumbnail->size, UprightOf(orientation, 96, 64)));
      Bitmap bitmap;
      CHECK(thumbnail && SUCCEEDED(DecodePng(factory.Get(), thumbnail->png, bitmap)));
      CHECK(thumbnail && bitmap.width == thumbnail->size.width && bitmap.height == thumbnail->size.height);
      CHECK(ShowsQuadrants(bitmap));
    }

    // A bound beyond the image answers it at its own size.
    const std::optional<ImageThumbnail> whole = ProbeThumbnail((dir / L"orientation_6.jpg").wstring(), 1000);
    CHECK(whole && Equal(whole->source, UprightSize{128, 192}) && Equal(whole->size, UprightSize{128, 192}));

    const std::filesystem::path text = dir / L"not_an_image.jpg";
    std::ofstream(text) << "not an image";
    CHECK(!ProbeSize(text.wstring()));
    CHECK(!ProbeThumbnail(text.wstring(), 96));

    std::filesystem::remove_all(dir, error);
  }
  CoUninitialize();
}
