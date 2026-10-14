#include "video_surface.h"

#include <dxgi.h>

#include <utility>

namespace ux {

using Microsoft::WRL::ComPtr;

VideoSurface::VideoSurface(ComPtr<ID3D11Device> device) : device_(std::move(device)) {}

HRESULT VideoSurface::Target(UINT width, UINT height, ComPtr<ID3D11Texture2D>& texture) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (target_.texture && target_.width == width && target_.height == height) {
    texture = target_.texture;
    return S_OK;
  }
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  Texture created;
  HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &created.texture);
  if (FAILED(hr)) return hr;
  ComPtr<IDXGIResource> resource;
  hr = created.texture.As(&resource);
  if (FAILED(hr)) return hr;
  hr = resource->GetSharedHandle(&created.handle);
  if (FAILED(hr)) return hr;
  created.width = width;
  created.height = height;
  target_ = std::move(created);
  texture = target_.texture;
  return S_OK;
}

void VideoSurface::Show() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (shown_.texture == target_.texture) return;
  if (shown_.texture) replaced_.push_back(shown_.texture);
  shown_ = target_;
}

const FlutterDesktopGpuSurfaceDescriptor* VideoSurface::Descriptor() {
  std::lock_guard<std::mutex> lock(mutex_);
  replaced_.clear();
  if (!shown_.texture) return nullptr;
  descriptor_ = {};
  descriptor_.struct_size = sizeof(descriptor_);
  descriptor_.handle = shown_.handle;
  descriptor_.width = descriptor_.visible_width = shown_.width;
  descriptor_.height = descriptor_.visible_height = shown_.height;
  descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
  return &descriptor_;
}

}  // namespace ux
