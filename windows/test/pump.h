#ifndef UX_TEST_PUMP_H_
#define UX_TEST_PUMP_H_

#include <windows.h>

#include <chrono>
#include <functional>

// Dispatches this thread's messages until [done] holds, or for [limit].
inline bool PumpUntil(const std::function<bool()>& done,
                      std::chrono::milliseconds limit = std::chrono::seconds(10)) {
  const auto deadline = std::chrono::steady_clock::now() + limit;
  while (!done()) {
    if (std::chrono::steady_clock::now() > deadline) return false;
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
  }
  return true;
}

#endif  // UX_TEST_PUMP_H_
