#ifndef UX_TEST_PNG_H_
#define UX_TEST_PNG_H_

#include <windows.h>

#include <wincodec.h>
#include <wrl/client.h>

#include <array>
#include <cstdint>
#include <vector>

using Rgb = std::array<uint8_t, 3>;

// A decoded image as 32-bit BGRA with straight alpha, its top row first.
struct Bitmap {
  UINT width = 0;
  UINT height = 0;
  std::vector<BYTE> bgra;

  Rgb At(UINT x, UINT y) const {
    const BYTE* pixel = &bgra[(static_cast<size_t>(y) * width + x) * 4];
    return {pixel[2], pixel[1], pixel[0]};
  }
};

// Decodes [png] into [bitmap], failing for any image but a PNG.
inline HRESULT DecodePng(IWICImagingFactory* factory, std::vector<uint8_t>& png, Bitmap& bitmap) {
  using Microsoft::WRL::ComPtr;
  ComPtr<IWICStream> stream;
  HRESULT hr = factory->CreateStream(&stream);
  if (FAILED(hr)) return hr;
  hr = stream->InitializeFromMemory(png.data(), static_cast<DWORD>(png.size()));
  if (FAILED(hr)) return hr;
  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
  if (FAILED(hr)) return hr;
  GUID container;
  hr = decoder->GetContainerFormat(&container);
  if (FAILED(hr)) return hr;
  if (container != GUID_ContainerFormatPng) return WINCODEC_ERR_UNKNOWNIMAGEFORMAT;
  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) return hr;
  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) return hr;
  hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) return hr;
  hr = converter->GetSize(&bitmap.width, &bitmap.height);
  if (FAILED(hr)) return hr;
  bitmap.bgra.resize(static_cast<size_t>(bitmap.width) * bitmap.height * 4);
  return converter->CopyPixels(nullptr, bitmap.width * 4, static_cast<UINT>(bitmap.bgra.size()), bitmap.bgra.data());
}

#endif  // UX_TEST_PNG_H_
