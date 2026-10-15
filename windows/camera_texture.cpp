#include "camera_texture.h"

namespace ux {

void RgbaFromRgb32(const uint8_t* top, LONG pitch, UINT width, UINT height, uint8_t* rgba) {
  for (UINT y = 0; y < height; y++) {
    const uint8_t* source = top + static_cast<ptrdiff_t>(pitch) * y;
    uint8_t* target = rgba + static_cast<size_t>(y) * width * 4;
    for (UINT x = 0; x < width; x++, source += 4, target += 4) {
      target[0] = source[2];
      target[1] = source[1];
      target[2] = source[0];
      target[3] = 0xFF;
    }
  }
}

void CameraTexture::Attach(std::function<void()> frame_available) {
  std::lock_guard<std::mutex> lock(mutex_);
  frame_available_ = std::move(frame_available);
}

void CameraTexture::Detach() {
  std::lock_guard<std::mutex> lock(mutex_);
  frame_available_ = nullptr;
}

bool CameraTexture::Write(const uint8_t* top, LONG pitch, UINT width, UINT height) {
  std::lock_guard<std::mutex> writing(writing_);
  back_.resize(static_cast<size_t>(width) * height * 4);
  RgbaFromRgb32(top, pitch, width, height, back_.data());
  const std::pair<UINT, UINT> size(width, height);
  const bool resized = written_ != size;
  written_ = size;
  std::lock_guard<std::mutex> lock(mutex_);
  front_.swap(back_);
  front_size_ = size;
  if (frame_available_) frame_available_();
  return resized;
}

const FlutterDesktopPixelBuffer* CameraTexture::Read() {
  mutex_.lock();
  if (front_.empty()) {
    mutex_.unlock();
    return nullptr;
  }
  buffer_.buffer = front_.data();
  buffer_.width = front_size_.first;
  buffer_.height = front_size_.second;
  buffer_.release_context = this;
  buffer_.release_callback = [](void* texture) { static_cast<CameraTexture*>(texture)->mutex_.unlock(); };
  return &buffer_;
}

}  // namespace ux
