#include "video_exporter_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "method_args.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableMap Event(int64_t id, const char* type) {
  return {
      {EncodableValue("sessionId"), EncodableValue(id)},
      {EncodableValue("type"), EncodableValue(type)},
  };
}

// The `done` or `error` event of session [id], whose file is [out_path].
EncodableMap Outcome(int64_t id, const std::string& out_path, const ExportOutcome& outcome) {
  if (const auto* done = std::get_if<ExportDone>(&outcome)) {
    EncodableMap event = Event(id, "done");
    event[EncodableValue("path")] = EncodableValue(out_path);
    event[EncodableValue("width")] = EncodableValue(static_cast<int64_t>(done->width));
    event[EncodableValue("height")] = EncodableValue(static_cast<int64_t>(done->height));
    event[EncodableValue("durationMs")] = EncodableValue(done->duration_ms);
    return event;
  }
  const auto* failed = std::get_if<ExportFailed>(&outcome);
  EncodableMap event = Event(id, "error");
  event[EncodableValue("code")] = EncodableValue(failed->code);
  event[EncodableValue("message")] = EncodableValue(failed->message);
  return event;
}

}  // namespace

VideoExporterPlugin::VideoExporterPlugin(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "ux/video/export", &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          messenger, "ux/video/export/events", &flutter::StandardMethodCodec::GetInstance())) {
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

VideoExporterPlugin::~VideoExporterPlugin() {
  channel_->SetMethodCallHandler(nullptr);
  events_->SetStreamHandler(nullptr);
  for (auto& [id, session] : sessions_) *session.cancelled = true;
  for (auto& [id, session] : sessions_) session.worker.join();
}

void VideoExporterPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                           std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "cancel") {
    const std::optional<int64_t> id = IntArg(args, "sessionId");
    if (!id) {
      result->Error("bad_args", "sessionId required");
      return;
    }
    if (const auto found = sessions_.find(*id); found != sessions_.end()) *found->second.cancelled = true;
    result->Success();
    return;
  }
  if (method != "start") {
    result->NotImplemented();
    return;
  }
  const std::optional<int64_t> id = IntArg(args, "sessionId");
  const std::optional<std::wstring> path = PathArg(args, "path");
  const std::optional<std::wstring> out_path = PathArg(args, "outPath");
  if (!id || !path || !out_path) {
    result->Error("bad_args", "sessionId, path, outPath required");
    return;
  }
  ExportRequest request;
  request.path = *path;
  request.out_path = *out_path;
  request.trim_start_ms = IntArg(args, "trimStartMs");
  request.trim_end_ms = IntArg(args, "trimEndMs");
  const auto* remove_audio = std::get_if<bool>(Arg(args, "removeAudio"));
  request.remove_audio = remove_audio != nullptr && *remove_audio;
  const std::optional<std::vector<double>> transform = DoublesArg(args, "transform");
  const std::optional<int64_t> out_width = IntArg(args, "outWidth");
  const std::optional<int64_t> out_height = IntArg(args, "outHeight");
  if (transform && transform->size() == 9 && out_width && out_height) {
    if (*out_width <= 0 || *out_height <= 0) {
      result->Error("bad_args", "outWidth and outHeight must be positive");
      return;
    }
    const std::vector<double>& t = *transform;
    request.geometry = ExportGeometry{Affine{t[0], t[1], t[2], t[3], t[4], t[5]}, static_cast<UINT>(*out_width),
                                      static_cast<UINT>(*out_height)};
  }
  request.video_bitrate = IntArg(args, "videoBitrate");
  if (request.video_bitrate && *request.video_bitrate <= 0) {
    result->Error("bad_args", "videoBitrate must be positive");
    return;
  }
  request.overlay_path = PathArg(args, "overlayPath");
  result->Success();
  Start(*id, std::move(request), *std::get_if<std::string>(Arg(args, "outPath")));
}

void VideoExporterPlugin::Start(int64_t id, ExportRequest request, std::string out_path) {
  // Dart numbers its sessions afresh after a hot restart.
  if (const auto found = sessions_.find(id); found != sessions_.end()) {
    *found->second.cancelled = true;
    found->second.worker.join();
    sessions_.erase(found);
  }
  auto cancelled = std::make_shared<std::atomic<bool>>(false);
  std::thread worker([this, id, cancelled, post = platform_.poster(), request = std::move(request),
                      out_path = std::move(out_path)]() {
    const ExportOutcome outcome = Export(
        request,
        [this, id, cancelled, post](double value) {
          post([this, id, cancelled, value]() {
            EncodableMap event = Event(id, "progress");
            event[EncodableValue("value")] = EncodableValue(value);
            Emit(id, cancelled, std::move(event));
          });
        },
        *cancelled);
    post([this, id, cancelled, event = Outcome(id, out_path, outcome)]() { Finish(id, cancelled, event); });
  });
  sessions_.emplace(id, Session{std::move(cancelled), std::move(worker)});
}

void VideoExporterPlugin::Emit(int64_t id, const std::shared_ptr<std::atomic<bool>>& cancelled, EncodableMap event) {
  const auto found = sessions_.find(id);
  if (found == sessions_.end() || found->second.cancelled != cancelled || !sink_) return;
  sink_->Success(EncodableValue(std::move(event)));
}

void VideoExporterPlugin::Finish(int64_t id, const std::shared_ptr<std::atomic<bool>>& cancelled, EncodableMap event) {
  const auto found = sessions_.find(id);
  if (found == sessions_.end() || found->second.cancelled != cancelled) return;
  found->second.worker.join();
  sessions_.erase(found);
  if (sink_) sink_->Success(EncodableValue(std::move(event)));
}

}  // namespace ux
