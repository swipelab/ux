#include <windows.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#include <optional>
#include <utility>

#include "../platform_thread.h"
#include "check.h"

namespace {

// Dispatches this thread's messages until [done] holds, or for [limit].
bool PumpUntil(const std::function<bool()>& done, std::chrono::milliseconds limit = std::chrono::seconds(10)) {
  const auto deadline = std::chrono::steady_clock::now() + limit;
  while (!done()) {
    if (std::chrono::steady_clock::now() > deadline) return false;
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
  }
  return true;
}

}  // namespace

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
