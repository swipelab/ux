#include "clipboard_plugin.h"

#include <windows.h>

#include <shellapi.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "dib.h"
#include "drop_data.h"
#include "text.h"

namespace ux {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// A read's reply, or none when another window keeps the clipboard open.
using Read = std::optional<EncodableValue>;

// The formats readImage reads, in the order it prefers them: the registered
// PNG format, then the bitmaps, which Windows also synthesizes from CF_BITMAP.
// The CF_DIB it synthesizes from a 32-bit CF_BITMAP repeats its masks and
// loses its last 12 bytes, so CF_DIBV5 comes first.
std::array<UINT, 3> ImageFormats() { return {RegisterClipboardFormatW(L"PNG"), CF_DIBV5, CF_DIB}; }

// Runs [read] with the clipboard open on the calling thread, and answers
// whether the clipboard opened.
bool WhileOpen(const std::function<void()>& read) {
  // Another window may hold the clipboard open for a moment.
  for (int attempt = 0; attempt < 10; attempt++) {
    if (OpenClipboard(nullptr)) {
      read();
      CloseClipboard();
      return true;
    }
    Sleep(10);
  }
  return false;
}

// The first of [formats] the open clipboard holds, with its bytes.
std::optional<std::pair<UINT, std::vector<uint8_t>>> FirstHeld(const std::array<UINT, 3>& formats) {
  for (const UINT format : formats) {
    const HANDLE data = GetClipboardData(format);
    if (data == nullptr) continue;
    const auto* bytes = static_cast<const uint8_t*>(GlobalLock(data));
    if (bytes == nullptr) continue;
    std::vector<uint8_t> copy(bytes, bytes + GlobalSize(data));
    GlobalUnlock(data);
    return std::make_pair(format, std::move(copy));
  }
  return std::nullopt;
}

// The PNG the clipboard holds, or the bitmap it holds encoded as PNG; null when
// it holds neither.
Read ReadImage() {
  const std::array<UINT, 3> formats = ImageFormats();
  std::optional<std::pair<UINT, std::vector<uint8_t>>> held;
  if (!WhileOpen([&] { held = FirstHeld(formats); })) return std::nullopt;
  if (!held) return EncodableValue();
  if (held->first == formats[0]) return EncodableValue(std::move(held->second));
  std::optional<std::vector<uint8_t>> png = DibToPng(held->second);
  return png ? EncodableValue(std::move(*png)) : EncodableValue();
}

// The path and name of each file the clipboard's CF_HDROP lists; null when it
// holds none.
Read ReadFiles() {
  std::optional<std::vector<std::wstring>> paths;
  if (!WhileOpen([&] {
        if (const auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP))) paths = PathsOf(drop);
      })) {
    return std::nullopt;
  }
  if (!paths) return EncodableValue();
  EncodableList files;
  for (const std::wstring& path : *paths) {
    const std::optional<std::string> utf8 = Utf8(path);
    const std::optional<std::string> name = Utf8(path.substr(path.find_last_of(L'\\') + 1));
    if (!utf8 || !name) continue;
    files.push_back(EncodableValue(EncodableMap{
        {EncodableValue("path"), EncodableValue(*utf8)},
        {EncodableValue("name"), EncodableValue(*name)},
    }));
  }
  return EncodableValue(std::move(files));
}

bool HasMedia() {
  const std::array<UINT, 3> formats = ImageFormats();
  return IsClipboardFormatAvailable(CF_HDROP) ||
         std::any_of(formats.begin(), formats.end(), [](UINT format) { return IsClipboardFormatAvailable(format); });
}

}  // namespace

ClipboardPlugin::ClipboardPlugin(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ux/clipboard", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

void ClipboardPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                       std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "hasMedia") {
    result->Success(EncodableValue(HasMedia()));
    return;
  }
  if (method != "readImage" && method != "readFiles") {
    result->NotImplemented();
    return;
  }
  std::shared_ptr<flutter::MethodResult<EncodableValue>> reply = std::move(result);
  platform_.Background<Read>(method == "readImage" ? ReadImage : ReadFiles, [reply](Read read) {
    if (read) {
      reply->Success(*read);
    } else {
      reply->Error("clipboard_busy", "another window keeps the clipboard open");
    }
  });
}

}  // namespace ux
