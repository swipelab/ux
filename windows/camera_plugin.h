#ifndef UX_CAMERA_PLUGIN_H_
#define UX_CAMERA_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>

#include "camera_instance.h"
#include "camera_texture.h"
#include "platform_thread.h"

namespace ux {

// `ux/camera` and `ux/camera/events`: one CameraInstance per handle, each
// previewing into a pixel-buffer texture of its own. One handle at a time holds
// a device, and one the microphone.
class CameraPlugin : public flutter::Plugin {
 public:
  explicit CameraPlugin(flutter::PluginRegistrarWindows* registrar);
  ~CameraPlugin() override;

  CameraPlugin(const CameraPlugin&) = delete;
  CameraPlugin& operator=(const CameraPlugin&) = delete;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  struct Camera {
    std::unique_ptr<CameraInstance> instance;
    // The device the handle holds.
    std::string id;
    bool audio;
    std::shared_ptr<CameraTexture> texture;
    int64_t texture_id;
    // Flutter reads it through a pointer until the texture is unregistered.
    std::shared_ptr<flutter::TextureVariant> variant;
  };

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<Result> result);
  void AvailableCameras(std::shared_ptr<Result> result);
  void Create(const flutter::EncodableMap* args, std::shared_ptr<Result> result);
  void HandleCameraCall(const std::string& method, const flutter::EncodableMap* args, Camera& camera,
                        int64_t handle, std::shared_ptr<Result> result);
  void Dispose(int64_t handle, std::shared_ptr<Result> result);
  void SetDescription(const flutter::EncodableMap* args, Camera& camera, int64_t handle,
                      std::shared_ptr<Result> result);
  void ReleaseClaims(const Camera& camera);
  void Unregister(Camera& camera);
  void Emit(int64_t handle, flutter::EncodableMap event);
  // The diagnostic for an empty camera list: the claims and the open handles.
  std::string EmptyDiagnostic() const;

  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::map<int64_t, Camera> cameras_;
  // Disposed handles whose instance is still closing.
  std::map<int64_t, Camera> closing_;
  std::set<std::string> devices_in_use_;
  bool audio_in_use_ = false;
  int64_t next_handle_ = 1;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_CAMERA_PLUGIN_H_
