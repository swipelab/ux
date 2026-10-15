#include "image_probe_plugin.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <utility>

#include "image_probe.h"
#include "method_args.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableValue Dimension(uint32_t length) { return EncodableValue(static_cast<int64_t>(length)); }

}  // namespace

ImageProbePlugin::ImageProbePlugin(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ux/image_probe", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
}

void ImageProbePlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                        std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method != "size" && method != "thumbnail") {
    result->NotImplemented();
    return;
  }
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  std::optional<std::wstring> path = PathArg(args, "path");
  if (!path) {
    result->Error("bad_args", "path is required");
    return;
  }
  std::shared_ptr<flutter::MethodResult<EncodableValue>> reply = std::move(result);
  const auto answer = [reply](EncodableValue value) { reply->Success(value); };
  if (method == "size") {
    platform_.Background<EncodableValue>(
        [path = std::move(*path)]() {
          const std::optional<UprightSize> size = ProbeSize(path);
          if (!size) return EncodableValue();
          return EncodableValue(EncodableMap{
              {EncodableValue("width"), Dimension(size->width)},
              {EncodableValue("height"), Dimension(size->height)},
          });
        },
        answer);
    return;
  }
  const std::optional<int64_t> max_longest = IntArg(args, "maxLongest");
  if (!max_longest || *max_longest <= 0) {
    reply->Error("bad_args", "maxLongest must be > 0");
    return;
  }
  platform_.Background<EncodableValue>(
      [path = std::move(*path), bound = static_cast<uint64_t>(*max_longest)]() {
        std::optional<ImageThumbnail> thumbnail = ProbeThumbnail(path, bound);
        if (!thumbnail) return EncodableValue();
        return EncodableValue(EncodableMap{
            {EncodableValue("sourceWidth"), Dimension(thumbnail->source.width)},
            {EncodableValue("sourceHeight"), Dimension(thumbnail->source.height)},
            {EncodableValue("width"), Dimension(thumbnail->size.width)},
            {EncodableValue("height"), Dimension(thumbnail->size.height)},
            {EncodableValue("png"), EncodableValue(std::move(thumbnail->png))},
        });
      },
      answer);
}

}  // namespace ux
