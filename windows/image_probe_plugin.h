#ifndef UX_IMAGE_PROBE_PLUGIN_H_
#define UX_IMAGE_PROBE_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>

#include <memory>

#include "platform_thread.h"

namespace ux {

// `ux/image_probe`: `size` and `thumbnail` of an image file, decoded through
// WIC off the platform thread.
class ImageProbePlugin : public flutter::Plugin {
 public:
  explicit ImageProbePlugin(flutter::BinaryMessenger* messenger);
  ~ImageProbePlugin() override;

  ImageProbePlugin(const ImageProbePlugin&) = delete;
  ImageProbePlugin& operator=(const ImageProbePlugin&) = delete;

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_IMAGE_PROBE_PLUGIN_H_
