#ifndef UX_NOTIFICATIONS_PLUGIN_H_
#define UX_NOTIFICATIONS_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>
#include <string>

#include "platform_thread.h"

namespace ux {

// `ux/notifications` and `ux/notifications/events`: toasts under the process's
// explicit AppUserModelID. While it lives, the plugin serves the toast
// activator the host names, through which Windows hands it each click on a
// toast: the click restores and raises the Flutter view's top-level window and
// emits `tap` with the toast's data.
class NotificationsPlugin : public flutter::Plugin {
 public:
  explicit NotificationsPlugin(flutter::PluginRegistrarWindows* registrar);
  ~NotificationsPlugin() override;

  NotificationsPlugin(const NotificationsPlugin&) = delete;
  NotificationsPlugin& operator=(const NotificationsPlugin&) = delete;

  // The class XPluginCApiSetToastActivator names, which plugins registered
  // afterwards serve.
  static void SetToastActivator(const GUID& activator);

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<Result> result);
  void RequestPermission(const std::wstring& app, Result& result);
  void Show(const std::wstring& app, const flutter::EncodableMap* args, Result& result);
  void OnActivated(const std::optional<std::wstring>& launch);
  void Emit(flutter::EncodableMap event);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  // CoRegisterClassObject's registration of the toast activator.
  std::optional<DWORD> activator_;
  PlatformThread platform_;
};

}  // namespace ux

#endif  // UX_NOTIFICATIONS_PLUGIN_H_
