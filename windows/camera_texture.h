#ifndef UX_CAMERA_TEXTURE_H_
#define UX_CAMERA_TEXTURE_H_

#include <windows.h>

#include <flutter_texture_registrar.h>

#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <utility>
#include <vector>

namespace ux {

// Converts [height] rows of [width] RGB32 pixels (blue, green, red and an
// unused byte), the top one at [top] and each [pitch] bytes after the one
// above it, into [rgba], opaque.
void RgbaFromRgb32(const uint8_t* top, LONG pitch, UINT width, UINT height, uint8_t* rgba);

// A camera preview's latest frame, as Flutter's pixel-buffer texture reads it.
// The capture engine writes frames on its threads while Flutter's raster thread
// reads them.
class CameraTexture {
 public:
  CameraTexture() = default;

  CameraTexture(const CameraTexture&) = delete;
  CameraTexture& operator=(const CameraTexture&) = delete;

  // Calls [frame_available] after each frame written from now on.
  void Attach(std::function<void()> frame_available);

  // Stops calling the callback Attach set.
  void Detach();

  // Stores an RGB32 frame, laid out as RgbaFromRgb32 reads it, and answers
  // whether its size differs from the previous frame's.
  bool Write(const uint8_t* top, LONG pitch, UINT width, UINT height);

  // The latest frame, held until Flutter releases it, or null before the first.
  const FlutterDesktopPixelBuffer* Read();

 private:
  // Held by the writer while it converts into back_.
  std::mutex writing_;
  std::vector<uint8_t> back_;
  std::optional<std::pair<UINT, UINT>> written_;

  // Held from Read until Flutter releases the frame.
  std::mutex mutex_;
  std::vector<uint8_t> front_;
  std::pair<UINT, UINT> front_size_;
  std::function<void()> frame_available_;
  FlutterDesktopPixelBuffer buffer_ = {};
};

}  // namespace ux

#endif  // UX_CAMERA_TEXTURE_H_
