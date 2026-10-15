#include "camera_devices.h"

#include <mfapi.h>
#include <mfidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <utility>

#include "text.h"

namespace ux {

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kConsentStore[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\";

std::optional<std::wstring> ConsentValue(HKEY root, const std::wstring& key) {
  DWORD size = 0;
  if (RegGetValueW(root, key.c_str(), L"Value", RRF_RT_REG_SZ, nullptr, nullptr, &size) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  std::wstring value(size / sizeof(wchar_t), L'\0');
  if (RegGetValueW(root, key.c_str(), L"Value", RRF_RT_REG_SZ, nullptr, value.data(), &size) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  value.resize(wcslen(value.c_str()));
  return value;
}

}  // namespace

HRESULT EnumerateCameras(std::vector<CameraDevice>& devices) {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return hr;
  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return hr;
  IMFActivate** sources = nullptr;
  UINT32 count = 0;
  hr = MFEnumDeviceSources(attributes.Get(), &sources, &count);
  if (FAILED(hr)) return hr;
  std::vector<CameraDevice> listed;
  for (UINT32 i = 0; i < count; i++) {
    wchar_t* link = nullptr;
    UINT32 length = 0;
    // A device without a symbolic link is one `create` could not open.
    if (SUCCEEDED(sources[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link,
                                                 &length))) {
      if (std::optional<std::string> id = Utf8(std::wstring(link, length))) listed.push_back({std::move(*id)});
      CoTaskMemFree(link);
    }
    sources[i]->Release();
  }
  CoTaskMemFree(sources);
  devices = std::move(listed);
  return S_OK;
}

bool CaptureAllowed(const wchar_t* capability) {
  const std::wstring key = kConsentStore + std::wstring(capability);
  return ConsentAllows({
      ConsentValue(HKEY_LOCAL_MACHINE, key),
      ConsentValue(HKEY_CURRENT_USER, key),
      ConsentValue(HKEY_CURRENT_USER, key + L"\\NonPackaged"),
  });
}

bool RequestCapture(const wchar_t* capability, bool allowed, const std::function<void(const std::wstring&)>& open) {
  if (!allowed) open(L"ms-settings:privacy-" + std::wstring(capability));
  return allowed;
}

bool ConsentAllows(const std::vector<std::optional<std::wstring>>& values) {
  return std::none_of(values.begin(), values.end(),
                      [](const std::optional<std::wstring>& value) { return value == std::wstring(L"Deny"); });
}

}  // namespace ux
