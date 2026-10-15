#include "video_device.h"

#include <utility>

namespace ux {

using Microsoft::WRL::ComPtr;

HRESULT VideoDevice::Create(IDXGIAdapter* adapter, std::shared_ptr<VideoDevice>& device) {
  std::shared_ptr<VideoDevice> created(new VideoDevice());
  HRESULT hr = created->media_.status();
  if (FAILED(hr)) return hr;
  hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                         D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                         D3D11_SDK_VERSION, &created->device_, nullptr, &created->context_);
  if (FAILED(hr)) return hr;
  ComPtr<ID3D10Multithread> multithread;
  hr = created->context_.As(&multithread);
  if (FAILED(hr)) return hr;
  multithread->SetMultithreadProtected(TRUE);
  UINT token = 0;
  hr = MFCreateDXGIDeviceManager(&token, &created->manager_);
  if (FAILED(hr)) return hr;
  hr = created->manager_->ResetDevice(created->device_.Get(), token);
  if (FAILED(hr)) return hr;
  device = std::move(created);
  return S_OK;
}

}  // namespace ux
