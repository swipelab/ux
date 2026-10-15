#include "window_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <utility>

#include "method_args.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Whether the foreground window is one of this thread's, which is the app's
// focus as WM_ACTIVATEAPP reports it.
bool HoldsForeground() {
  const HWND foreground = GetForegroundWindow();
  return foreground != nullptr && GetWindowThreadProcessId(foreground, nullptr) == GetCurrentThreadId();
}

}  // namespace

bool KeepAwake(bool enabled) {
  return SetThreadExecutionState(enabled ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED : ES_CONTINUOUS) != 0;
}

WindowPlugin::WindowPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "ux/window", &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "ux/window/events", &flutter::StandardMethodCodec::GetInstance())),
      window_proc_(registrar->RegisterTopLevelWindowProcDelegate(
          [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
            return HandleWindowProc(window, message, wparam, lparam);
          })) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_ = std::move(sink);
        Emit(HoldsForeground());
        return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_.reset();
        return nullptr;
      }));
}

WindowPlugin::~WindowPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_);
}

void WindowPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() != "keepAwake") {
    result->NotImplemented();
    return;
  }
  const auto* enabled = std::get_if<bool>(Arg(std::get_if<EncodableMap>(call.arguments()), "enabled"));
  if (enabled == nullptr) {
    result->Error("bad_args", "enabled required");
    return;
  }
  if (!KeepAwake(*enabled)) {
    result->Error("keep_awake_failed", "SetThreadExecutionState failed");
    return;
  }
  result->Success();
}

std::optional<LRESULT> WindowPlugin::HandleWindowProc(HWND, UINT message, WPARAM wparam, LPARAM) {
  if (message == WM_ACTIVATEAPP) {
    Emit(wparam != FALSE);
  } else if (message == WM_DESTROY) {
    KeepAwake(false);
  }
  return std::nullopt;
}

void WindowPlugin::Emit(bool focused) {
  if (!sink_) return;
  sink_->Success(EncodableValue(EncodableMap{
      {EncodableValue("type"), EncodableValue("focus")},
      {EncodableValue("focused"), EncodableValue(focused)},
  }));
}

}  // namespace ux
