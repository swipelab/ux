#include "camera_plugin.h"

#include <windows.h>

#include <shellapi.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <utility>
#include <variant>
#include <vector>

#include "camera_devices.h"
#include "media_foundation.h"
#include "method_args.h"
#include "text.h"

namespace ux {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

using Listing = std::variant<std::vector<CameraDevice>, HRESULT>;

void OpenUri(const std::wstring& uri) {
  ShellExecuteW(nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

void BadArgs(flutter::MethodResult<EncodableValue>& result, const std::string& where) {
  result.Error("bad_args", "Bad arguments for " + where);
}

// [code] for a camera failure, or permission_denied where Windows's Privacy &
// security settings refused the camera.
void Fail(flutter::MethodResult<EncodableValue>& result, const CameraError& error, const char* code) {
  if (error.hr == E_ACCESSDENIED) {
    result.Error("permission_denied", "camera");
  } else {
    result.Error(code, error.message);
  }
}

void ReplyPath(flutter::MethodResult<EncodableValue>& result, const CameraResult<std::wstring>& written,
               const char* code) {
  if (const auto* error = std::get_if<CameraError>(&written)) {
    result.Error(code, error->message);
    return;
  }
  const std::optional<std::string> path = Utf8(std::get<std::wstring>(written));
  if (!path) {
    result.Error(code, "the file's path is not UTF-16");
    return;
  }
  result.Success(EncodableValue(EncodableMap{{EncodableValue("path"), EncodableValue(*path)}}));
}

EncodableMap Described(FrameSize size) {
  return {
      {EncodableValue("previewSize"), EncodableValue(SizeWire(size.width, size.height))},
      {EncodableValue("previewRotationQuarterTurns"), EncodableValue(0)},
  };
}

}  // namespace

CameraPlugin::CameraPlugin(flutter::PluginRegistrarWindows* registrar)
    : textures_(registrar->texture_registrar()),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "ux/camera", &flutter::StandardMethodCodec::GetInstance())),
      events_(std::make_unique<flutter::EventChannel<EncodableValue>>(
          registrar->messenger(), "ux/camera/events", &flutter::StandardMethodCodec::GetInstance())) {
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

CameraPlugin::~CameraPlugin() {
  for (auto* cameras : {&cameras_, &closing_}) {
    for (auto& [handle, camera] : *cameras) Unregister(camera);
  }
}

void CameraPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "availableCameras") {
    AvailableCameras(std::move(result));
    return;
  }
  if (method == "create") {
    Create(args, std::move(result));
    return;
  }
  if (method == "cameraPermissionStatus" || method == "audioPermissionStatus") {
    result->Success(EncodableValue(CaptureAllowed(method == "cameraPermissionStatus" ? L"webcam" : L"microphone")));
    return;
  }
  if (method == "requestCameraPermission" || method == "requestAudioPermission") {
    const wchar_t* capability = method == "requestCameraPermission" ? L"webcam" : L"microphone";
    result->Success(EncodableValue(RequestCapture(capability, CaptureAllowed(capability), OpenUri)));
    return;
  }
  if (method == "openSettings") {
    OpenUri(L"ms-settings:privacy-webcam");
    result->Success();
    return;
  }
  if (method != "initialize" && method != "dispose" && method != "setDescription" && method != "setFlashMode" &&
      method != "lockCaptureOrientation" && method != "unlockCaptureOrientation" && method != "takePicture" &&
      method != "startVideoRecording" && method != "stopVideoRecording") {
    result->NotImplemented();
    return;
  }
  const std::optional<int64_t> handle = IntArg(args, "handle");
  if (!handle) {
    BadArgs(*result, "missing handle");
    return;
  }
  const auto found = cameras_.find(*handle);
  if (found == cameras_.end()) {
    result->Error("disposed", "No camera for handle " + std::to_string(*handle));
    return;
  }
  HandleCameraCall(method, args, found->second, *handle, std::move(result));
}

void CameraPlugin::AvailableCameras(std::shared_ptr<Result> result) {
  platform_.Background<Listing>(
      []() -> Listing {
        MediaWork media;
        if (FAILED(media.status())) return media.status();
        std::vector<CameraDevice> devices;
        const HRESULT hr = EnumerateCameras(devices);
        if (FAILED(hr)) return hr;
        return devices;
      },
      [this, result](Listing listing) {
        if (const auto* failed = std::get_if<HRESULT>(&listing)) {
          result->Error("no_camera", "cannot list the cameras (" + Hex(*failed) + ")");
          return;
        }
        const auto& devices = std::get<std::vector<CameraDevice>>(listing);
        if (devices.empty()) Emit(-1, DiagnosticEvent(EmptyDiagnostic()));
        result->Success(EncodableValue(CamerasWire(devices)));
      });
}

void CameraPlugin::Create(const EncodableMap* args, std::shared_ptr<Result> result) {
  const auto* id = std::get_if<std::string>(Arg(args, "cameraId"));
  const auto* audio = std::get_if<bool>(Arg(args, "enableAudio"));
  const std::optional<std::wstring> link = id ? Utf16(*id) : std::nullopt;
  if (!link || audio == nullptr) {
    BadArgs(*result, "create");
    return;
  }
  if (devices_in_use_.count(*id) > 0) {
    result->Error("device_busy", *id);
    return;
  }
  if (*audio && audio_in_use_) {
    result->Error("audio_busy");
    return;
  }
  auto texture = std::make_shared<CameraTexture>();
  auto variant = std::make_shared<flutter::TextureVariant>(
      flutter::PixelBufferTexture([texture](size_t, size_t) { return texture->Read(); }));
  const int64_t texture_id = textures_->RegisterTexture(variant.get());
  if (texture_id < 0) {
    result->Error("init_failed", "Flutter takes no pixel-buffer texture");
    return;
  }
  texture->Attach([textures = textures_, texture_id] { textures->MarkTextureFrameAvailable(texture_id); });
  const int64_t handle = next_handle_++;
  devices_in_use_.insert(*id);
  if (*audio) audio_in_use_ = true;
  auto instance = std::make_unique<CameraInstance>(
      platform_.poster(), [this, handle](EncodableMap event) { Emit(handle, std::move(event)); }, texture);
  Camera& camera = cameras_[handle] = Camera{std::move(instance), *id, *audio, texture, texture_id, variant};
  camera.instance->Open(*link, *audio, [this, handle, texture_id, result](CameraResult<FrameSize> opened) {
    if (const auto* size = std::get_if<FrameSize>(&opened)) {
      EncodableMap created = Described(*size);
      created[EncodableValue("handle")] = EncodableValue(handle);
      created[EncodableValue("textureId")] = EncodableValue(texture_id);
      result->Success(EncodableValue(std::move(created)));
      return;
    }
    const auto failed = cameras_.find(handle);
    ReleaseClaims(failed->second);
    Unregister(failed->second);
    cameras_.erase(failed);
    Fail(*result, std::get<CameraError>(opened), "init_failed");
  });
}

void CameraPlugin::HandleCameraCall(const std::string& method, const EncodableMap* args, Camera& camera,
                                    int64_t handle, std::shared_ptr<Result> result) {
  if (method == "initialize") {
    camera.instance->StartPreview([result](std::optional<CameraError> error) {
      if (error) {
        Fail(*result, *error, "init_failed");
      } else {
        result->Success();
      }
    });
  } else if (method == "dispose") {
    Dispose(handle, std::move(result));
  } else if (method == "setDescription") {
    SetDescription(args, camera, handle, std::move(result));
  } else if (method == "setFlashMode" && !StringArg(args, "mode")) {
    BadArgs(*result, method);
  } else if (method == "lockCaptureOrientation" && !StringArg(args, "orientation")) {
    BadArgs(*result, method);
  } else if (method == "setFlashMode" || method == "lockCaptureOrientation" || method == "unlockCaptureOrientation") {
    // A webcam has neither a flash nor an orientation of its own.
    result->Success();
  } else if (method == "stopVideoRecording") {
    camera.instance->StopRecording(
        [result](CameraResult<std::wstring> written) { ReplyPath(*result, written, "recorder_failed"); });
  } else if (!StringArg(args, "snapshotOrientation")) {
    BadArgs(*result, method);
  } else if (method == "takePicture") {
    camera.instance->TakePicture(
        [result](CameraResult<std::wstring> written) { ReplyPath(*result, written, "take_picture_failed"); });
  } else {
    camera.instance->StartRecording([result](std::optional<CameraError> error) {
      if (error) {
        result->Error("recorder_failed", error->message);
      } else {
        result->Success();
      }
    });
  }
}

void CameraPlugin::Dispose(int64_t handle, std::shared_ptr<Result> result) {
  // The device and the microphone are free for another handle at once, while
  // this one closes.
  auto disposed = cameras_.extract(handle);
  ReleaseClaims(disposed.mapped());
  Camera& camera = closing_.insert(std::move(disposed)).position->second;
  camera.instance->Close([this, handle, result] {
    const auto closed = closing_.find(handle);
    Unregister(closed->second);
    closing_.erase(closed);
    result->Success();
  });
}

void CameraPlugin::SetDescription(const EncodableMap* args, Camera& camera, int64_t handle,
                                  std::shared_ptr<Result> result) {
  const auto* id = std::get_if<std::string>(Arg(args, "cameraId"));
  const std::optional<std::wstring> link = id ? Utf16(*id) : std::nullopt;
  if (!link) {
    BadArgs(*result, "setDescription");
    return;
  }
  const std::string held = camera.id;
  if (*id != held && devices_in_use_.count(*id) > 0) {
    result->Error("device_busy", *id);
    return;
  }
  devices_in_use_.insert(*id);
  camera.instance->SetDevice(*link, [this, handle, held, id = *id, result](CameraResult<FrameSize> opened) {
    const auto* size = std::get_if<FrameSize>(&opened);
    const auto found = cameras_.find(handle);
    // A handle disposed meanwhile released the device it held then.
    if (size != nullptr && found != cameras_.end()) {
      if (held != id) devices_in_use_.erase(held);
      found->second.id = id;
    } else if (held != id) {
      devices_in_use_.erase(id);
    }
    if (size == nullptr) {
      Fail(*result, std::get<CameraError>(opened), "init_failed");
    } else {
      result->Success(EncodableValue(Described(*size)));
    }
  });
}

void CameraPlugin::ReleaseClaims(const Camera& camera) {
  devices_in_use_.erase(camera.id);
  if (camera.audio) audio_in_use_ = false;
}

void CameraPlugin::Unregister(Camera& camera) {
  camera.texture->Detach();
  textures_->UnregisterTexture(camera.texture_id, [variant = camera.variant] {});
}

void CameraPlugin::Emit(int64_t handle, EncodableMap event) {
  if (sink_) sink_->Success(CameraEvent(handle, std::move(event)));
}

std::string CameraPlugin::EmptyDiagnostic() const {
  std::string devices;
  for (const std::string& id : devices_in_use_) devices += (devices.empty() ? "\"" : ", \"") + id + "\"";
  std::string instances;
  for (const auto& [handle, camera] : cameras_) instances += (instances.empty() ? "" : ", ") + std::to_string(handle);
  return "availableCameras: empty devicesInUse=[" + devices + "] audioInUse=" + (audio_in_use_ ? "true" : "false") +
         " instances=[" + instances + "]";
}

}  // namespace ux
