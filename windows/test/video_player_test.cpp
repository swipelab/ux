#include <windows.h>

#include <dxgi.h>
#include <wrl/client.h>

#include <chrono>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "../platform_thread.h"
#include "../video_device.h"
#include "../video_player_instance.h"
#include "check.h"
#include "support.h"

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

void VideoPlayerSuite() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  ComPtr<IDXGIFactory1> factory;
  ComPtr<IDXGIAdapter> adapter;
  CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
  CHECK(SUCCEEDED(factory->EnumAdapters(0, &adapter)));
  std::shared_ptr<ux::VideoDevice> device;
  CHECK(SUCCEEDED(ux::VideoDevice::Create(adapter.Get(), device)));
  if (!device) return;
  const std::wstring broken = TempPath(L"ux_video_player_broken.mp4");
  CHECK(WriteBytes(broken, {'n', 'o', 't', ' ', 'a', ' ', 'v', 'i', 'd', 'e', 'o'}));
  ux::PlatformThread platform;

  // A source that fails before initialize emits playback_failed, then fails initialize with its error.
  {
    std::vector<EncodableMap> events;
    std::shared_ptr<ux::VideoPlayerInstance> player;
    CHECK(SUCCEEDED(ux::VideoPlayerInstance::Create(
        device, platform.poster(), [&events](EncodableMap event) { events.push_back(std::move(event)); }, player)));
    player->Open(broken, [] {});
    CHECK(PumpUntil([&events] { return !events.empty(); }));
    std::optional<ux::VideoPrepared> prepared;
    player->Prepare([&prepared](ux::VideoPrepared result) { prepared = std::move(result); });
    const auto* failed = prepared ? std::get_if<ux::VideoFailed>(&*prepared) : nullptr;
    CHECK(failed);
    const std::vector<EncodableMap> emitted = {{
        {EncodableValue("event"), EncodableValue("error")},
        {EncodableValue("code"), EncodableValue("playback_failed")},
        {EncodableValue("description"), EncodableValue(failed ? failed->message : "")},
    }};
    CHECK(events == emitted);
  }

  // A source that fails while initialize waits fails it and emits nothing.
  {
    std::vector<EncodableMap> events;
    std::shared_ptr<ux::VideoPlayerInstance> player;
    CHECK(SUCCEEDED(ux::VideoPlayerInstance::Create(
        device, platform.poster(), [&events](EncodableMap event) { events.push_back(std::move(event)); }, player)));
    player->Open(broken, [] {});
    std::optional<ux::VideoPrepared> prepared;
    player->Prepare([&prepared](ux::VideoPrepared result) { prepared = std::move(result); });
    CHECK(PumpUntil([&prepared] { return prepared.has_value(); }));
    CHECK(prepared && std::holds_alternative<ux::VideoFailed>(*prepared));
    CHECK(events.empty());
  }

  // A player opened once disposed, whose engine refuses the source at once, emits nothing.
  {
    std::vector<EncodableMap> events;
    std::shared_ptr<ux::VideoPlayerInstance> player;
    CHECK(SUCCEEDED(ux::VideoPlayerInstance::Create(
        device, platform.poster(), [&events](EncodableMap event) { events.push_back(std::move(event)); }, player)));
    player->Dispose();
    player->Open(broken, [] {});
    CHECK(!PumpUntil([&events] { return !events.empty(); }, std::chrono::milliseconds(500)));
  }

  DeleteFileW(broken.c_str());
}
