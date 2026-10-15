#ifndef UX_VIDEO_PLAYER_PLUGIN_H_
#define UX_VIDEO_PLAYER_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <map>
#include <memory>

#include "platform_thread.h"
#include "video_device.h"
#include "video_player_instance.h"

namespace ux {

// `ux/video` and `ux/video/events`: one VideoPlayerInstance per handle, each
// rendering into a Flutter texture of its own.
class VideoPlayerPlugin : public flutter::Plugin {
 public:
  explicit VideoPlayerPlugin(flutter::PluginRegistrarWindows* registrar);
  ~VideoPlayerPlugin() override;

  VideoPlayerPlugin(const VideoPlayerPlugin&) = delete;
  VideoPlayerPlugin& operator=(const VideoPlayerPlugin&) = delete;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  struct Player {
    std::shared_ptr<VideoPlayerInstance> instance;
    int64_t texture_id;
    // Flutter reads it through a pointer until the texture is unregistered.
    std::shared_ptr<flutter::TextureVariant> texture;
  };

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<Result> result);
  void Create(const flutter::EncodableMap* args, Result& result);
  void Release(Player& player);
  void Emit(int64_t handle, flutter::EncodableMap event);

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  // Created by the first `create`.
  std::shared_ptr<VideoDevice> device_;
  std::map<int64_t, Player> players_;
  int64_t next_handle_ = 1;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_VIDEO_PLAYER_PLUGIN_H_
