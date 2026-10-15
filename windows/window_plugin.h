#ifndef UX_WINDOW_PLUGIN_H_
#define UX_WINDOW_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>

namespace ux {

// Holds the display on for the calling thread while [enabled], or ends the
// hold, through SetThreadExecutionState. Answers whether Windows took the
// state.
bool KeepAwake(bool enabled);

// `ux/window` and `ux/window/events`: `keepAwake`, and the app's focus, which
// WM_ACTIVATEAPP on the Flutter view's top-level window reports and the
// foreground window seeds on listen. The window's destruction ends a hold.
class WindowPlugin : public flutter::Plugin {
 public:
  explicit WindowPlugin(flutter::PluginRegistrarWindows* registrar);
  ~WindowPlugin() override;

  WindowPlugin(const WindowPlugin&) = delete;
  WindowPlugin& operator=(const WindowPlugin&) = delete;

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  std::optional<LRESULT> HandleWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  void Emit(bool focused);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  int window_proc_;
};

}  // namespace ux

#endif  // UX_WINDOW_PLUGIN_H_
