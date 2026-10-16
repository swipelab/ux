#include "video_player_plugin.h"

#include <dxgi.h>
#include <wrl/client.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <optional>
#include <string>
#include <utility>

#include "method_args.h"
#include "text.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

// The path of a `file://<path>` URI, with either separator, or none for any
// other URI.
std::optional<std::wstring> FilePath(const std::string& uri) {
  constexpr char kScheme[] = "file://";
  if (uri.rfind(kScheme, 0) != 0) return std::nullopt;
  std::optional<std::wstring> path = Utf16(uri.substr(sizeof(kScheme) - 1));
  if (path) std::replace(path->begin(), path->end(), L'/', L'\\');
  return path;
}

void Reply(flutter::MethodResult<EncodableValue>& result, const VideoPrepared& prepared) {
  if (const auto* ready = std::get_if<VideoReady>(&prepared)) {
    result.Success(EncodableValue(EncodableMap{
        {EncodableValue("size"), EncodableValue(VideoSize(ready->width, ready->height))},
        // The contract's durationMs is 0 for a source with no finite duration.
        {EncodableValue("durationMs"), EncodableValue(ready->duration_ms.value_or(0))},
        {EncodableValue("rotationQuarterTurns"), EncodableValue(0)},
    }));
  } else if (const auto* failed = std::get_if<VideoFailed>(&prepared)) {
    result.Error("decode_failed", failed->message);
  } else {
    result.Error("disposed", "player disposed before it was ready");
  }
}

}  // namespace

VideoPlayerPlugin::VideoPlayerPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      textures_(registrar->texture_registrar()),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "ux/video", &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "ux/video/events", &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_ = std::move(sink);
        return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_.reset();
        return nullptr;
      }));
}

VideoPlayerPlugin::~VideoPlayerPlugin() {
  for (auto& [handle, player] : players_) Release(player);
}

void VideoPlayerPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                         std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "create") {
    Create(args, *result);
    return;
  }
  if (method != "initialize" && method != "dispose" && method != "play" && method != "pause" &&
      method != "seekTo" && method != "setLooping" && method != "setVolume" && method != "setPlaybackSpeed") {
    result->NotImplemented();
    return;
  }
  const std::optional<int64_t> handle = IntArg(args, "handle");
  if (!handle) {
    result->Error("bad_args", "missing handle");
    return;
  }
  const auto found = players_.find(*handle);
  if (found == players_.end()) {
    result->Error("disposed", "no player for handle " + std::to_string(*handle));
    return;
  }
  VideoPlayerInstance& instance = *found->second.instance;
  if (method == "initialize") {
    instance.Prepare([result = std::shared_ptr<Result>(std::move(result))](VideoPrepared prepared) {
      Reply(*result, prepared);
    });
    return;
  }
  if (method == "dispose") {
    Release(found->second);
    players_.erase(found);
  } else if (method == "play") {
    instance.Play();
  } else if (method == "pause") {
    instance.Pause();
  } else if (method == "seekTo") {
    const std::optional<int64_t> position = IntArg(args, "positionMs");
    if (!position) {
      result->Error("bad_args", "seekTo");
      return;
    }
    instance.SeekTo(*position);
  } else if (method == "setLooping") {
    const auto* loop = std::get_if<bool>(Arg(args, "loop"));
    if (loop == nullptr) {
      result->Error("bad_args", "setLooping");
      return;
    }
    instance.SetLooping(*loop);
  } else {
    const auto* value = std::get_if<double>(Arg(args, method == "setVolume" ? "volume" : "rate"));
    if (value == nullptr) {
      result->Error("bad_args", method);
      return;
    }
    if (method == "setVolume") {
      instance.SetVolume(*value);
    } else {
      instance.SetPlaybackSpeed(*value);
    }
  }
  result->Success();
}

void VideoPlayerPlugin::Create(const EncodableMap* args, Result& result) {
  const auto* uri = std::get_if<std::string>(Arg(args, "uri"));
  if (uri == nullptr) {
    result.Error("bad_args", "create");
    return;
  }
  const std::optional<std::wstring> path = FilePath(*uri);
  if (!path) {
    result.Error("bad_args", "create uri");
    return;
  }
  if (!device_) {
    ComPtr<IDXGIAdapter> adapter;
    if (!registrar_->GetGraphicsAdapter(&adapter)) {
      result.Error("create_failed", "Flutter renders on no DXGI adapter");
      return;
    }
    const HRESULT hr = VideoDevice::Create(adapter.Get(), device_);
    if (FAILED(hr)) {
      result.Error("create_failed", "cannot create the video device (" + Hex(hr) + ")");
      return;
    }
  }
  const int64_t handle = next_handle_;
  std::shared_ptr<VideoPlayerInstance> instance;
  const HRESULT hr = VideoPlayerInstance::Create(
      device_, platform_.poster(), [this, handle](EncodableMap event) { Emit(handle, std::move(event)); }, instance);
  if (FAILED(hr)) {
    result.Error("create_failed", "cannot create the player (" + Hex(hr) + ")");
    return;
  }
  auto texture = std::make_shared<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
                                 [surface = instance->surface()](size_t, size_t) { return surface->Descriptor(); }));
  const int64_t texture_id = textures_->RegisterTexture(texture.get());
  if (texture_id < 0) {
    result.Error("create_failed", "Flutter takes no GPU surface texture");
    return;
  }
  next_handle_++;
  players_.emplace(handle, Player{instance, texture_id, texture});
  result.Success(EncodableValue(EncodableMap{
      {EncodableValue("handle"), EncodableValue(handle)},
      {EncodableValue("textureId"), EncodableValue(texture_id)},
  }));
  // After the answer: the player emits only from tasks posted after it, so every event reaches Dart after the handle.
  instance->Open(*path, [textures = textures_, texture_id]() { textures->MarkTextureFrameAvailable(texture_id); });
}

void VideoPlayerPlugin::Release(Player& player) {
  player.instance->Dispose();
  textures_->UnregisterTexture(player.texture_id, [texture = player.texture]() {});
}

void VideoPlayerPlugin::Emit(int64_t handle, EncodableMap event) {
  if (!sink_) return;
  event[EncodableValue("handle")] = EncodableValue(handle);
  sink_->Success(EncodableValue(std::move(event)));
}

}  // namespace ux
