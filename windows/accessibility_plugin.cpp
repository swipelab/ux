#include "accessibility_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <utility>

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

}  // namespace

bool ReducesMotion() {
  BOOL animates = TRUE;
  SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animates, 0);
  return !animates;
}

AccessibilityPlugin::AccessibilityPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "ux/accessibility/events", &flutter::StandardMethodCodec::GetInstance())),
      window_proc_(registrar->RegisterTopLevelWindowProcDelegate(
          [this](HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
            return HandleWindowProc(window, message, wparam, lparam);
          })) {
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_ = std::move(sink);
        Emit();
        return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sink_.reset();
        return nullptr;
      }));
}

AccessibilityPlugin::~AccessibilityPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_);
}

std::optional<LRESULT> AccessibilityPlugin::HandleWindowProc(HWND, UINT message, WPARAM, LPARAM) {
  if (message == WM_SETTINGCHANGE) Emit();
  return std::nullopt;
}

void AccessibilityPlugin::Emit() {
  if (!sink_) return;
  sink_->Success(EncodableValue(EncodableMap{
      {EncodableValue("type"), EncodableValue("reduceMotion")},
      {EncodableValue("reduced"), EncodableValue(ReducesMotion())},
  }));
}

}  // namespace ux
