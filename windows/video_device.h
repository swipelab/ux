#ifndef UX_VIDEO_DEVICE_H_
#define UX_VIDEO_DEVICE_H_

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <mfapi.h>
#include <wrl/client.h>

#include <memory>

namespace ux {

// The Direct3D 11 device the video players share, on the adapter Flutter
// renders with, and the DXGI device manager that hands it to their media
// engines. Media Foundation stays loaded and started while it lives.
class VideoDevice {
 public:
  // Sets [device] to a device on [adapter], or answers why there is none, as
  // where Media Foundation does not load.
  static HRESULT Create(IDXGIAdapter* adapter, std::shared_ptr<VideoDevice>& device);
  ~VideoDevice();

  VideoDevice(const VideoDevice&) = delete;
  VideoDevice& operator=(const VideoDevice&) = delete;

  const Microsoft::WRL::ComPtr<ID3D11Device>& device() const { return device_; }
  const Microsoft::WRL::ComPtr<ID3D11DeviceContext>& context() const { return context_; }
  const Microsoft::WRL::ComPtr<IMFDXGIDeviceManager>& manager() const { return manager_; }

 private:
  explicit VideoDevice(HMODULE media_foundation) : media_foundation_(media_foundation) {}

  const HMODULE media_foundation_;
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> manager_;
};

}  // namespace ux

#endif  // UX_VIDEO_DEVICE_H_
