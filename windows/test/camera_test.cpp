#include <windows.h>

#include <cwctype>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <system_error>
#include <variant>
#include <vector>

#include "../camera_devices.h"
#include "../camera_instance.h"
#include "../camera_texture.h"
#include "../platform_thread.h"
#include "check.h"
#include "pump.h"

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// Whether [path] is [directory], then `ux_camera_`, an uppercase GUID without
// braces and [extension].
bool IsCapture(const std::wstring& path, const std::wstring& directory, const std::wstring& extension) {
  const std::wstring prefix = directory + L"ux_camera_";
  if (path.size() != prefix.size() + 36 + extension.size() || path.compare(0, prefix.size(), prefix) != 0 ||
      path.compare(path.size() - extension.size(), extension.size(), extension) != 0) {
    return false;
  }
  for (size_t i = 0; i < 36; i++) {
    const wchar_t c = path[prefix.size() + i];
    const bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? c != L'-' : !std::iswxdigit(c) || std::iswlower(c)) return false;
  }
  return true;
}

}  // namespace

void CameraSuite() {
  // An mfplat.dll that is no image, found before System32's, stands for a
  // Windows without Media Foundation.
  std::error_code error;
  const std::filesystem::path dir = std::filesystem::temp_directory_path(error) / L"ux_test_camera";
  std::filesystem::create_directories(dir, error);
  std::ofstream(dir / L"mfplat.dll") << "not an image";
  CHECK(SetDllDirectoryW(dir.c_str()));
  CHECK(ux::CameraFoundation().status() == HRESULT_FROM_WIN32(ERROR_BAD_EXE_FORMAT));
  CHECK(SetDllDirectoryW(nullptr));
  std::filesystem::remove_all(dir, error);
  {
    ux::CameraFoundation foundation;
    CHECK(SUCCEEDED(foundation.status()));
    std::vector<ux::CameraDevice> devices;
    CHECK(SUCCEEDED(ux::EnumerateCameras(devices)));
  }

  const std::string link = "\\\\?\\usb#vid_046d&pid_0825&mi_00#7&1b2c3d4e&0&0000#{e5323777-f976-4f5b-9b55-b94699c46e44}";
  CHECK(ux::CamerasWire({{link}}) == flutter::EncodableList({EncodableValue(EncodableMap{
                                          {EncodableValue("id"), EncodableValue(link)},
                                          {EncodableValue("lens"), EncodableValue("back")},
                                          {EncodableValue("sensorOrientation"), EncodableValue(0)},
                                      })}));
  CHECK(ux::CameraEvent(3, ux::PreviewSizeChangedEvent(1280, 720)) ==
        EncodableValue(EncodableMap{
            {EncodableValue("handle"), EncodableValue(int64_t{3})},
            {EncodableValue("event"), EncodableValue("previewSizeChanged")},
            {EncodableValue("previewSize"), EncodableValue(EncodableMap{
                                                {EncodableValue("width"), EncodableValue(1280.0)},
                                                {EncodableValue("height"), EncodableValue(720.0)},
                                            })},
        }));
  CHECK(ux::CameraEvent(3, ux::SessionErrorEvent("capture engine error")) ==
        EncodableValue(EncodableMap{
            {EncodableValue("handle"), EncodableValue(int64_t{3})},
            {EncodableValue("event"), EncodableValue("sessionError")},
            {EncodableValue("code"), EncodableValue("session_runtime_error")},
            {EncodableValue("description"), EncodableValue("capture engine error")},
        }));
  CHECK(ux::CameraEvent(-1, ux::DiagnosticEvent("availableCameras: empty")) ==
        EncodableValue(EncodableMap{
            {EncodableValue("handle"), EncodableValue(int64_t{-1})},
            {EncodableValue("event"), EncodableValue("diagnostic")},
            {EncodableValue("message"), EncodableValue("availableCameras: empty")},
        }));

  wchar_t temp[MAX_PATH + 1];
  const std::wstring directory(temp, GetTempPathW(MAX_PATH + 1, temp));
  std::wstring photo;
  std::wstring video;
  CHECK(SUCCEEDED(ux::CapturePath(L"jpg", photo)));
  CHECK(SUCCEEDED(ux::CapturePath(L"mp4", video)));
  CHECK(directory.back() == L'\\');
  CHECK(IsCapture(photo, directory, L".jpg"));
  CHECK(IsCapture(video, directory, L".mp4"));
  CHECK(photo.substr(0, photo.size() - 4) != video.substr(0, video.size() - 4));

  // Smooth frames before pixels, pixels before rate, nothing past 1920×1080.
  CHECK(ux::PreferredFormat({{1920, 1080, 5}, {1280, 720, 30}, {640, 480, 30}, {3840, 2160, 30}}) == size_t{1});
  CHECK(ux::PreferredFormat({{1280, 720, 15}, {1280, 720, 30}}) == size_t{1});
  CHECK(!ux::PreferredFormat({{3840, 2160, 30}}));

  CHECK(ux::ConsentAllows({std::nullopt, std::wstring(L"Allow"), std::nullopt}));
  CHECK(!ux::ConsentAllows({std::wstring(L"Allow"), std::nullopt, std::wstring(L"Deny")}));

  // One pixel a row, bottom-up: the top row is the second in memory.
  const uint8_t rows[] = {0x10, 0x20, 0x30, 0x00, 0x40, 0x50, 0x60, 0x00};
  ux::CameraTexture texture;
  int frames = 0;
  texture.Attach([&frames] { frames++; });
  CHECK(texture.Read() == nullptr);
  CHECK(texture.Write(rows + 4, -4, 1, 2));
  CHECK(!texture.Write(rows + 4, -4, 1, 2));
  const FlutterDesktopPixelBuffer* frame = texture.Read();
  CHECK(frame != nullptr && frame->width == 1 && frame->height == 2);
  if (frame != nullptr) {
    CHECK(std::vector<uint8_t>(frame->buffer, frame->buffer + 8) ==
          std::vector<uint8_t>({0x60, 0x50, 0x40, 0xFF, 0x30, 0x20, 0x10, 0xFF}));
    frame->release_callback(frame->release_context);
  }
  texture.Detach();
  CHECK(texture.Write(rows, 4, 2, 1));
  CHECK(frames == 2);

  // A camera that does not open answers why, and closes.
  {
    ux::PlatformThread platform;
    ux::CameraInstance instance(platform.poster(), [](EncodableMap) {}, std::make_shared<ux::CameraTexture>());
    std::optional<ux::CameraResult<ux::FrameSize>> opened;
    instance.Open(L"\\\\?\\ux#no-such-camera", true,
                  [&opened](ux::CameraResult<ux::FrameSize> result) { opened = std::move(result); });
    CHECK(PumpUntil([&opened] { return opened.has_value(); }));
    CHECK(opened && std::holds_alternative<ux::CameraError>(*opened));
    bool closed = false;
    instance.Close([&closed] { closed = true; });
    CHECK(PumpUntil([&closed] { return closed; }));
  }
}
