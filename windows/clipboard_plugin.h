#ifndef UX_CLIPBOARD_PLUGIN_H_
#define UX_CLIPBOARD_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>

#include <memory>

#include "platform_thread.h"

namespace ux {

// `ux/clipboard`, which reads and never writes: `readFiles` answers CF_HDROP's
// paths and names, `readImage` the bytes of the registered PNG format or a
// CF_DIBV5 or CF_DIB bitmap encoded as PNG, and `hasMedia` whether the
// clipboard holds any of these, without reading them. The reads run off the
// platform thread.
class ClipboardPlugin : public flutter::Plugin {
 public:
  explicit ClipboardPlugin(flutter::BinaryMessenger* messenger);

  ClipboardPlugin(const ClipboardPlugin&) = delete;
  ClipboardPlugin& operator=(const ClipboardPlugin&) = delete;

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_CLIPBOARD_PLUGIN_H_
