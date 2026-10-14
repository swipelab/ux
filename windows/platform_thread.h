#ifndef UX_PLATFORM_THREAD_H_
#define UX_PLATFORM_THREAD_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>

namespace ux {

// Runs work off the thread that creates it, and hands each result back to that
// thread through its message loop.
class PlatformThread {
 public:
  PlatformThread();
  ~PlatformThread();

  PlatformThread(const PlatformThread&) = delete;
  PlatformThread& operator=(const PlatformThread&) = delete;

  // Runs [work] on a thread of its own, then [done] with its value on this
  // object's thread. [done] does not run once this object is destroyed.
  template <typename T>
  void Background(std::function<T()> work, std::function<void(T)> done) {
    std::thread([queue = queue_, work = std::move(work), done = std::move(done)]() {
      auto value = std::make_shared<T>(work());
      Post(queue, [done, value]() { done(std::move(*value)); });
    }).detach();
  }

 private:
  struct Queue {
    std::mutex mutex;
    HWND window = nullptr;
  };

  static void Post(const std::shared_ptr<Queue>& queue, std::function<void()> task);
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);

  std::shared_ptr<Queue> queue_;
};

}  // namespace ux

#endif  // UX_PLATFORM_THREAD_H_
