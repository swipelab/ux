#include <windows.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <optional>
#include <utility>

#include "../platform_thread.h"
#include "check.h"
#include "support.h"

void PlatformThreadSuite() {
  {
    ux::PlatformThread platform;
    std::optional<DWORD> worker;
    std::optional<DWORD> receiver;
    std::optional<int> value;
    platform.Background<std::pair<DWORD, int>>(
        []() { return std::make_pair(GetCurrentThreadId(), 42); },
        [&](std::pair<DWORD, int> done) {
          worker = done.first;
          receiver = GetCurrentThreadId();
          value = done.second;
        });
    CHECK(PumpUntil([&] { return value.has_value(); }));
    CHECK(value == 42);
    CHECK(worker && *worker != GetCurrentThreadId());
    CHECK(receiver == GetCurrentThreadId());
  }

  std::atomic<bool> release{false};
  bool delivered = false;
  auto token = std::make_shared<int>(0);
  const std::weak_ptr<int> held = token;
  {
    ux::PlatformThread platform;
    platform.Background<int>(
        [&release]() {
          while (!release) Sleep(1);
          return 1;
        },
        [token, &delivered](int) { delivered = true; });
  }
  token.reset();
  release = true;
  CHECK(PumpUntil([&] { return held.expired(); }));
  PumpUntil([] { return false; }, std::chrono::milliseconds(200));
  CHECK(!delivered);
}
