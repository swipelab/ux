#ifndef UX_WIC_H_
#define UX_WIC_H_

#include <windows.h>

#include <wincodec.h>

#include <cstdint>
#include <vector>

namespace ux {

// COM on the calling thread while it lives, in the apartment the thread already
// has, if any.
class ComScope {
 public:
  ComScope() : initialized_(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {}
  ~ComScope() {
    if (initialized_) CoUninitialize();
  }

  ComScope(const ComScope&) = delete;
  ComScope& operator=(const ComScope&) = delete;

 private:
  const bool initialized_;
};

// Encodes [source] into [png] with WIC's PNG encoder, as 32-bit BGRA.
HRESULT EncodePng(IWICImagingFactory* factory, IWICBitmapSource* source, std::vector<uint8_t>& png);

}  // namespace ux

#endif  // UX_WIC_H_
