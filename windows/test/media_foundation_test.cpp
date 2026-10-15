#include <windows.h>

#include <dxgi.h>
#include <wrl/client.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <system_error>
#include <utility>
#include <variant>

#include "../camera_instance.h"
#include "../camera_texture.h"
#include "../media_foundation.h"
#include "../platform_thread.h"
#include "../text.h"
#include "../video_device.h"
#include "../video_export.h"
#include "../video_thumbnail.h"
#include "check.h"
#include "support.h"

using Microsoft::WRL::ComPtr;

void MediaFoundationSuite() {
  ComPtr<IDXGIFactory1> factory;
  ComPtr<IDXGIAdapter> adapter;
  CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
  CHECK(SUCCEEDED(factory->EnumAdapters(0, &adapter)));

  // An mfplat.dll that is no image, found before System32's, stands for a
  // Windows without Media Foundation.
  std::error_code error;
  const std::filesystem::path dir = std::filesystem::temp_directory_path(error) / L"ux_test_media_foundation";
  std::filesystem::create_directories(dir, error);
  std::ofstream(dir / L"mfplat.dll") << "not an image";
  CHECK(SetDllDirectoryW(dir.c_str()));
  const HRESULT missing = HRESULT_FROM_WIN32(ERROR_BAD_EXE_FORMAT);
  const std::string unavailable = "Media Foundation is unavailable (" + ux::Hex(missing) + ")";
  CHECK(ux::MediaFoundation().status() == missing);
  std::shared_ptr<ux::VideoDevice> device;
  CHECK(ux::VideoDevice::Create(adapter.Get(), device) == missing);
  CHECK(!device);
  const std::wstring source = TempPath(L"ux_media_foundation_source.mp4");
  const ux::ThumbnailResult thumbnail = ux::VideoThumbnail(source, 0, std::nullopt, std::nullopt);
  const auto* thumbnail_failed = std::get_if<ux::ThumbnailFailed>(&thumbnail);
  CHECK(thumbnail_failed && thumbnail_failed->message == unavailable);
  ux::ExportRequest request;
  request.path = source;
  request.out_path = TempPath(L"ux_media_foundation_out.mp4");
  const ux::ExportOutcome outcome = ux::Export(request, [](double) {}, std::atomic<bool>{false});
  const auto* export_failed = std::get_if<ux::ExportFailed>(&outcome);
  CHECK(export_failed && export_failed->code == "session_failed" && export_failed->message == unavailable);
  {
    ux::PlatformThread platform;
    ux::CameraInstance camera(platform.poster(), [](flutter::EncodableMap) {}, std::make_shared<ux::CameraTexture>());
    std::optional<ux::CameraResult<ux::FrameSize>> opened;
    camera.Open(L"\\\\?\\ux#no-such-camera", false,
                [&opened](ux::CameraResult<ux::FrameSize> result) { opened = std::move(result); });
    CHECK(PumpUntil([&opened] { return opened.has_value(); }));
    const auto* camera_failed = opened ? std::get_if<ux::CameraError>(&*opened) : nullptr;
    CHECK(camera_failed && camera_failed->message == unavailable);
  }

  // So does an mf.dll that is no image, beside System32's mfplat.dll and
  // mfreadwrite.dll.
  std::filesystem::remove(dir / L"mfplat.dll", error);
  std::ofstream(dir / L"mf.dll") << "not an image";
  CHECK(ux::MediaFoundation().status() == missing);

  CHECK(SetDllDirectoryW(nullptr));
  CHECK(SUCCEEDED(ux::MediaFoundation().status()));
  CHECK(SUCCEEDED(ux::VideoDevice::Create(adapter.Get(), device)));
  CHECK(device && device->manager());
  device.reset();
  std::filesystem::remove_all(dir, error);
}
