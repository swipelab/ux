#ifndef UX_VIDEO_EXPORTER_PLUGIN_H_
#define UX_VIDEO_EXPORTER_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <thread>

#include "platform_thread.h"
#include "video_export.h"

namespace ux {

// `ux/video/export` and `ux/video/export/events`: each `start` runs its
// export on a thread of its own, which `cancel` stops.
class VideoExporterPlugin : public flutter::Plugin {
 public:
  explicit VideoExporterPlugin(flutter::BinaryMessenger* messenger);
  ~VideoExporterPlugin() override;

  VideoExporterPlugin(const VideoExporterPlugin&) = delete;
  VideoExporterPlugin& operator=(const VideoExporterPlugin&) = delete;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  struct Session {
    // Also tells a session from a later one under its id.
    std::shared_ptr<std::atomic<bool>> cancelled;
    std::thread worker;
  };

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<Result> result);
  void Start(int64_t id, ExportRequest request, std::string out_path);
  // Emits [event] for session [id] while [cancelled] is that session's.
  void Emit(int64_t id, const std::shared_ptr<std::atomic<bool>>& cancelled, flutter::EncodableMap event);
  void Finish(int64_t id, const std::shared_ptr<std::atomic<bool>>& cancelled, flutter::EncodableMap event);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::map<int64_t, Session> sessions_;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_VIDEO_EXPORTER_PLUGIN_H_
