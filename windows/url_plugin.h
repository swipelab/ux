#ifndef UX_URL_PLUGIN_H_
#define UX_URL_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar.h>

#include <memory>

namespace ux {

// `ux/url`: `launch` opens a URL with its registered handler.
class UrlPlugin : public flutter::Plugin {
 public:
  explicit UrlPlugin(flutter::BinaryMessenger* messenger);

  UrlPlugin(const UrlPlugin&) = delete;
  UrlPlugin& operator=(const UrlPlugin&) = delete;

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace ux

#endif  // UX_URL_PLUGIN_H_
