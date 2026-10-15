#include "notifications_plugin.h"

#include <unknwn.h>

#include <NotificationActivationCallback.h>
#include <shobjidl.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <map>
#include <utility>

#include "text.h"
#include "toast.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::UI::Notifications::NotificationSetting;
using winrt::Windows::UI::Notifications::ToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationManager;

constexpr char kNoAppUserModelId[] =
    "the process has no explicit AppUserModelID to show toasts under (SetCurrentProcessExplicitAppUserModelID)";

std::optional<GUID>& ToastActivatorClass() {
  static std::optional<GUID> activator;
  return activator;
}

// The class object of the toast activator, and the activator it makes: hands
// each click's launch argument to [activated].
class ToastActivator : public winrt::implements<ToastActivator, IClassFactory, INotificationActivationCallback> {
 public:
  explicit ToastActivator(std::function<void(std::optional<std::wstring>)> activated)
      : activated_(std::move(activated)) {}

  HRESULT __stdcall CreateInstance(IUnknown* outer, REFIID iid, void** object) noexcept final {
    *object = nullptr;
    if (outer != nullptr) return CLASS_E_NOAGGREGATION;
    return QueryInterface(iid, object);
  }

  HRESULT __stdcall LockServer(BOOL) noexcept final { return S_OK; }

  HRESULT __stdcall Activate(LPCWSTR, LPCWSTR arguments, const NOTIFICATION_USER_INPUT_DATA*, ULONG) noexcept final {
    activated_(arguments == nullptr ? std::nullopt : std::optional<std::wstring>(arguments));
    return S_OK;
  }

 private:
  std::function<void(std::optional<std::wstring>)> activated_;
};

std::optional<std::wstring> AppUserModelId() {
  PWSTR id = nullptr;
  if (FAILED(GetCurrentProcessExplicitAppUserModelID(&id))) return std::nullopt;
  std::wstring value(id);
  CoTaskMemFree(id);
  return value;
}

const EncodableValue* Arg(const EncodableMap* args, const char* key) {
  if (args == nullptr) return nullptr;
  const auto it = args->find(EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

std::optional<std::wstring> StringArg(const EncodableMap* args, const char* key) {
  const auto* value = std::get_if<std::string>(Arg(args, key));
  if (value == nullptr) return std::nullopt;
  return Utf16(*value);
}

// The `data` argument, a map of strings, which an absent `data` leaves empty;
// none when it holds anything else.
std::optional<std::map<std::wstring, std::wstring>> DataArg(const EncodableMap* args) {
  std::map<std::wstring, std::wstring> data;
  const EncodableValue* value = Arg(args, "data");
  if (value == nullptr) return data;
  const auto* map = std::get_if<EncodableMap>(value);
  if (map == nullptr) return std::nullopt;
  for (const auto& [key, entry] : *map) {
    const auto* utf8_key = std::get_if<std::string>(&key);
    const auto* utf8_entry = std::get_if<std::string>(&entry);
    if (utf8_key == nullptr || utf8_entry == nullptr) return std::nullopt;
    std::optional<std::wstring> wide_key = Utf16(*utf8_key);
    std::optional<std::wstring> wide_entry = Utf16(*utf8_entry);
    if (!wide_key || !wide_entry) return std::nullopt;
    data.emplace(std::move(*wide_key), std::move(*wide_entry));
  }
  return data;
}

}  // namespace

void NotificationsPlugin::SetToastActivator(const GUID& activator) {
  ToastActivatorClass() = activator;
}

NotificationsPlugin::NotificationsPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "ux/notifications", &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "ux/notifications/events", &flutter::StandardMethodCodec::GetInstance())) {
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
  const std::optional<GUID> activator = ToastActivatorClass();
  if (!activator) return;
  const winrt::com_ptr<ToastActivator> factory =
      winrt::make_self<ToastActivator>([post = platform_.poster(), this](std::optional<std::wstring> launch) {
        post([this, launch = std::move(launch)]() { OnActivated(launch); });
      });
  DWORD cookie = 0;
  if (SUCCEEDED(CoRegisterClassObject(*activator, static_cast<IClassFactory*>(factory.get()), CLSCTX_LOCAL_SERVER,
                                      REGCLS_MULTIPLEUSE, &cookie))) {
    activator_ = cookie;
  }
}

NotificationsPlugin::~NotificationsPlugin() {
  if (activator_) CoRevokeClassObject(*activator_);
}

void NotificationsPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                           std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  if (method != "requestPermission" && method != "show" && method != "cancelByThread" && method != "cancelAll") {
    result->NotImplemented();
    return;
  }
  const std::optional<std::wstring> app = AppUserModelId();
  if (!app) {
    result->Error("no_app_user_model_id", kNoAppUserModelId);
    return;
  }
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  try {
    if (method == "requestPermission") {
      RequestPermission(*app, *result);
    } else if (method == "show") {
      Show(*app, args, *result);
    } else if (method == "cancelByThread") {
      const std::optional<std::wstring> thread = StringArg(args, "threadId");
      if (!thread) {
        result->Error("bad_args", "cancelByThread expects threadId");
        return;
      }
      ToastNotificationManager::History().RemoveGroup(*thread, *app);
      result->Success();
    } else {
      ToastNotificationManager::History().Clear(*app);
      result->Success();
    }
  } catch (const winrt::hresult_error& error) {
    result->Error(method + "_failed", winrt::to_string(error.message()) + " (" + Hex(error.code()) + ")");
  }
}

void NotificationsPlugin::RequestPermission(const std::wstring& app, Result& result) {
  const bool granted = ToastNotificationManager::CreateToastNotifier(app).Setting() == NotificationSetting::Enabled;
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("authorization")},
      {EncodableValue("granted"), EncodableValue(granted)},
  });
  result.Success(EncodableValue(granted));
}

void NotificationsPlugin::Show(const std::wstring& app, const EncodableMap* args, Result& result) {
  const std::optional<std::wstring> id = StringArg(args, "id");
  const std::optional<std::wstring> title = StringArg(args, "title");
  const std::optional<std::wstring> body = StringArg(args, "body");
  const std::optional<std::map<std::wstring, std::wstring>> data = DataArg(args);
  if (!id || !title || !body || !data) {
    result.Error("bad_args", "show expects id/title/body");
    return;
  }
  ToastNotification toast(ToastXml(*title, *body, *data));
  toast.Tag(*id);
  if (const std::optional<std::wstring> thread = StringArg(args, "threadId")) toast.Group(*thread);
  ToastNotificationManager::CreateToastNotifier(app).Show(toast);
  result.Success();
}

void NotificationsPlugin::OnActivated(const std::optional<std::wstring>& launch) {
  if (flutter::FlutterView* view = registrar_->GetView()) {
    const HWND window = GetAncestor(view->GetNativeWindow(), GA_ROOT);
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
  }
  const std::optional<std::map<std::wstring, std::wstring>> data = launch ? ToastData(*launch) : std::nullopt;
  if (!data) return;
  EncodableMap payload;
  for (const auto& [key, value] : *data) {
    const std::optional<std::string> utf8_key = Utf8(key);
    const std::optional<std::string> utf8_value = Utf8(value);
    if (!utf8_key || !utf8_value) return;
    payload.emplace(EncodableValue(*utf8_key), EncodableValue(*utf8_value));
  }
  Emit(EncodableMap{
      {EncodableValue("type"), EncodableValue("tap")},
      {EncodableValue("data"), EncodableValue(std::move(payload))},
  });
}

void NotificationsPlugin::Emit(EncodableMap event) {
  if (sink_) sink_->Success(EncodableValue(std::move(event)));
}

}  // namespace ux
