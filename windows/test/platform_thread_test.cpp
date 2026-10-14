#include <windows.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <memory>

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
    std::atomic<DWORD> worker{0};
    DWORD receiver = 0;
    int value = 0;
    platform.Background<int>(
        [&worker]() {
          worker = GetCurrentThreadId();
          return 42;
        },
        [&](int done) {
          receiver = GetCurrentThreadId();
          value = done;
        });
    CHECK(PumpUntil([&] { return value != 0; }));
    CHECK(value == 42);
    CHECK(worker != 0 && worker != GetCurrentThreadId());
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
