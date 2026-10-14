#include <windows.h>

#include <dxgi.h>
#include <wrl/client.h>

#include <filesystem>
#include <fstream>
#include <memory>
#include <system_error>

#include "../video_device.h"
#include "check.h"

using Microsoft::WRL::ComPtr;

void VideoDeviceSuite() {
  ComPtr<IDXGIFactory1> factory;
  ComPtr<IDXGIAdapter> adapter;
  CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
  CHECK(SUCCEEDED(factory->EnumAdapters(0, &adapter)));

  // An mfplat.dll that is no image, found before System32's, stands for a
  // Windows without Media Foundation.
  std::error_code error;
  const std::filesystem::path dir = std::filesystem::temp_directory_path(error) / L"ux_test_video_device";
  std::filesystem::create_directories(dir, error);
  std::ofstream(dir / L"mfplat.dll") << "not an image";
  CHECK(SetDllDirectoryW(dir.c_str()));
  std::shared_ptr<ux::VideoDevice> device;
  CHECK(ux::VideoDevice::Create(adapter.Get(), device) == HRESULT_FROM_WIN32(ERROR_BAD_EXE_FORMAT));
  CHECK(!device);

  CHECK(SetDllDirectoryW(nullptr));
  CHECK(SUCCEEDED(ux::VideoDevice::Create(adapter.Get(), device)));
  CHECK(device && device->manager());
  device.reset();
  std::filesystem::remove_all(dir, error);
}
