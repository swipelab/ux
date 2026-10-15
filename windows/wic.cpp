#include "wic.h"

#include <wrl/client.h>

namespace ux {

using Microsoft::WRL::ComPtr;

HRESULT EncodePng(IWICImagingFactory* factory, IWICBitmapSource* source, std::vector<uint8_t>& png) {
  ComPtr<IStream> stream;
  HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
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
  UINT width = 0;
  UINT height = 0;
  hr = source->GetSize(&width, &height);
  if (FAILED(hr)) return hr;
  hr = frame->SetSize(width, height);
  if (FAILED(hr)) return hr;
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  hr = frame->SetPixelFormat(&format);
  if (FAILED(hr)) return hr;
  hr = frame->WriteSource(source, nullptr);
  if (FAILED(hr)) return hr;
  hr = frame->Commit();
  if (FAILED(hr)) return hr;
  hr = encoder->Commit();
  if (FAILED(hr)) return hr;
  STATSTG stat;
  hr = stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr)) return hr;
  hr = stream->Seek(LARGE_INTEGER{}, STREAM_SEEK_SET, nullptr);
  if (FAILED(hr)) return hr;
  png.resize(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG read = 0;
  hr = stream->Read(png.data(), static_cast<ULONG>(png.size()), &read);
  if (FAILED(hr)) return hr;
  return read == png.size() ? S_OK : E_UNEXPECTED;
}

}  // namespace ux
