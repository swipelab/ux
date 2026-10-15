#include "image_probe.h"

#include <windows.h>

#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <utility>

#include "wic.h"

namespace ux {

namespace {

using Microsoft::WRL::ComPtr;

// The first frame of an image file, as its codec decodes it.
struct Frame {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmapFrameDecode> decode;
  UINT width = 0;
  UINT height = 0;
  // The EXIF orientation, 1 to 8, still to apply to the decoded pixels.
  USHORT orientation = 1;
};

// [width] by [height] once EXIF [orientation] applies; 5 to 8 turn it a quarter.
UprightSize UprightOf(USHORT orientation, UINT width, UINT height) {
  return orientation >= 5 ? UprightSize{height, width} : UprightSize{width, height};
}

// System.Photo.Orientation is what a codec leaves to apply: a JPEG's EXIF tag,
// while the HEIF codec turns its image by the rotation item and reports 1.
USHORT OrientationOf(IWICBitmapFrameDecode* frame) {
  ComPtr<IWICMetadataQueryReader> reader;
  if (FAILED(frame->GetMetadataQueryReader(&reader))) return 1;
  PROPVARIANT value;
  PropVariantInit(&value);
  USHORT orientation = 1;
  if (SUCCEEDED(reader->GetMetadataByName(L"System.Photo.Orientation", &value)) && value.vt == VT_UI2 &&
      value.uiVal >= 1 && value.uiVal <= 8) {
    orientation = value.uiVal;
  }
  PropVariantClear(&value);
  return orientation;
}

// The flip and rotation that turn a frame of EXIF [orientation] upright. WIC
// flips before it rotates.
WICBitmapTransformOptions UprightTransform(USHORT orientation) {
  switch (orientation) {
    case 2:
      return WICBitmapTransformFlipHorizontal;
    case 3:
      return WICBitmapTransformRotate180;
    case 4:
      return WICBitmapTransformFlipVertical;
    case 5:
      return static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 6:
      return WICBitmapTransformRotate90;
    case 7:
      return static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 8:
      return WICBitmapTransformRotate270;
    default:
      return WICBitmapTransformRotate0;
  }
}

HRESULT Open(const std::wstring& path, Frame& frame) {
  HRESULT hr =
      CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&frame.factory));
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapDecoder> decoder;
  hr = frame.factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                &decoder);
  if (FAILED(hr)) return hr;
  hr = decoder->GetFrame(0, &frame.decode);
  if (FAILED(hr)) return hr;
  hr = frame.decode->GetSize(&frame.width, &frame.height);
  if (FAILED(hr)) return hr;
  frame.orientation = OrientationOf(frame.decode.Get());
  return S_OK;
}

HRESULT Convert(IWICImagingFactory* factory, REFWICPixelFormatGUID format, ComPtr<IWICBitmapSource>& source) {
  ComPtr<IWICFormatConverter> converter;
  HRESULT hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) return hr;
  hr = converter->Initialize(source.Get(), format, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return hr;
  source = std::move(converter);
  return S_OK;
}

// Sets [source] to [frame] scaled to [width] by [height], which are in its
// stored orientation, then turned upright.
HRESULT Render(const Frame& frame, UINT width, UINT height, ComPtr<IWICBitmapSource>& source) {
  IWICImagingFactory* factory = frame.factory.Get();
  source = frame.decode;
  // Scaled with premultiplied alpha, so transparent pixels lend no colour.
  HRESULT hr = Convert(factory, GUID_WICPixelFormat32bppPBGRA, source);
  if (FAILED(hr)) return hr;
  if (width != frame.width || height != frame.height) {
    ComPtr<IWICBitmapScaler> scaler;
    hr = factory->CreateBitmapScaler(&scaler);
    if (FAILED(hr)) return hr;
    hr = scaler->Initialize(source.Get(), width, height, WICBitmapInterpolationModeHighQualityCubic);
    if (FAILED(hr)) return hr;
    source = std::move(scaler);
  }
  const WICBitmapTransformOptions upright = UprightTransform(frame.orientation);
  if (upright != WICBitmapTransformRotate0) {
    // The rotator reads its source a pixel at a time, which a decoder serves
    // by decoding again, so it reads the scaled pixels from memory.
    ComPtr<IWICBitmap> scaled;
    hr = factory->CreateBitmapFromSource(source.Get(), WICBitmapCacheOnLoad, &scaled);
    if (FAILED(hr)) return hr;
    ComPtr<IWICBitmapFlipRotator> rotator;
    hr = factory->CreateBitmapFlipRotator(&rotator);
    if (FAILED(hr)) return hr;
    hr = rotator->Initialize(scaled.Get(), upright);
    if (FAILED(hr)) return hr;
    source = std::move(rotator);
  }
  return Convert(factory, GUID_WICPixelFormat32bppBGRA, source);
}

}  // namespace

std::optional<UprightSize> ProbeSize(const std::wstring& path) {
  ComScope com;
  Frame frame;
  if (FAILED(Open(path, frame))) return std::nullopt;
  return UprightOf(frame.orientation, frame.width, frame.height);
}

std::optional<ImageThumbnail> ProbeThumbnail(const std::wstring& path, uint64_t max_longest) {
  ComScope com;
  Frame frame;
  if (FAILED(Open(path, frame))) return std::nullopt;
  const UINT longest = (std::max)(frame.width, frame.height);
  const auto target = static_cast<UINT>((std::min)(max_longest, uint64_t{longest}));
  const auto scaled = [&](UINT length) {
    return (std::max)(1u, static_cast<UINT>((uint64_t{length} * target + longest / 2) / longest));
  };
  const UINT width = scaled(frame.width);
  const UINT height = scaled(frame.height);
  ComPtr<IWICBitmapSource> source;
  std::vector<uint8_t> png;
  if (FAILED(Render(frame, width, height, source)) || FAILED(EncodePng(frame.factory.Get(), source.Get(), png))) {
    return std::nullopt;
  }
  return ImageThumbnail{UprightOf(frame.orientation, frame.width, frame.height),
                        UprightOf(frame.orientation, width, height), std::move(png)};
}

}  // namespace ux
