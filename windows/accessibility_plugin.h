#ifndef UX_ACCESSIBILITY_PLUGIN_H_
#define UX_ACCESSIBILITY_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>

namespace ux {

// Whether Windows's Animation effects setting is off, which
// SPI_GETCLIENTAREAANIMATION reads.
bool ReducesMotion();

// `ux/accessibility/events`: ReducesMotion as reduceMotion, sent when Dart
// listens and on each WM_SETTINGCHANGE the Flutter view's top-level window
// receives.
class AccessibilityPlugin : public flutter::Plugin {
 public:
  explicit AccessibilityPlugin(flutter::PluginRegistrarWindows* registrar);
  ~AccessibilityPlugin() override;

  AccessibilityPlugin(const AccessibilityPlugin&) = delete;
  AccessibilityPlugin& operator=(const AccessibilityPlugin&) = delete;

 private:
  std::optional<LRESULT> HandleWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  void Emit();

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  int window_proc_;
};

}  // namespace ux

#endif  // UX_ACCESSIBILITY_PLUGIN_H_
