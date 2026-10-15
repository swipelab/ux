#ifndef UX_VIDEO_SURFACE_H_
#define UX_VIDEO_SURFACE_H_

#include <d3d11.h>
#include <wrl/client.h>

#include <flutter_texture_registrar.h>

#include <mutex>
#include <vector>

namespace ux {

// The BGRA texture a player's frames land in, which Flutter's raster thread
// opens through its DXGI shared handle. One thread draws into it and another
// reads its descriptor.
class VideoSurface {
 public:
  explicit VideoSurface(Microsoft::WRL::ComPtr<ID3D11Device> device);

  VideoSurface(const VideoSurface&) = delete;
  VideoSurface& operator=(const VideoSurface&) = delete;

  // Sets [texture] to the texture the next [width]×[height] frame is drawn
  // into: the shown one while the size holds, a new one when it changes.
  HRESULT Target(UINT width, UINT height, Microsoft::WRL::ComPtr<ID3D11Texture2D>& texture);

  // Shows the texture Target last set once its frame is drawn and flushed.
  void Show();

  // The shown texture as Flutter opens it, or null before the first frame.
  const FlutterDesktopGpuSurfaceDescriptor* Descriptor();

 private:
  struct Texture {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    HANDLE handle = nullptr;
    UINT width = 0;
    UINT height = 0;
  };

  const Microsoft::WRL::ComPtr<ID3D11Device> device_;
  std::mutex mutex_;
  Texture target_;
  Texture shown_;
  // Textures replaced since Flutter last asked, which it may still be opening.
  std::vector<Microsoft::WRL::ComPtr<ID3D11Texture2D>> replaced_;
  FlutterDesktopGpuSurfaceDescriptor descriptor_ = {};
};

}  // namespace ux

#endif  // UX_VIDEO_SURFACE_H_
