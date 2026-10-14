#include "url_plugin.h"

#include <windows.h>

#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "text.h"

namespace ux {

namespace {

// Whether the shell opened [url] with the handler registered for its scheme.
bool Launch(const std::string& url) {
  const std::optional<std::wstring> wide = Utf16(url);
  if (!wide) return false;
  const HINSTANCE opened = ShellExecuteW(nullptr, L"open", wide->c_str(), nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(opened) > 32;
}

}  // namespace

UrlPlugin::UrlPlugin(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "ux/url", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

UrlPlugin::~UrlPlugin() { channel_->SetMethodCallHandler(nullptr); }

void UrlPlugin::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                                 std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "launch") {
    result->NotImplemented();
    return;
  }
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string* url = nullptr;
  if (args != nullptr) {
    const auto it = args->find(flutter::EncodableValue("url"));
    if (it != args->end()) url = std::get_if<std::string>(&it->second);
  }
  result->Success(flutter::EncodableValue(url != nullptr && Launch(*url)));
}

}  // namespace ux
