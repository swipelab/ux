#include "platform_thread.h"

namespace ux {

namespace {

constexpr UINT kRun = WM_APP;

HINSTANCE Module() {
  HMODULE module = nullptr;
  GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                     reinterpret_cast<LPCWSTR>(&Module), &module);
  return module;
}

}  // namespace

PlatformThread::PlatformThread() : queue_(std::make_shared<Queue>()) {
  static const ATOM atom = [] {
    WNDCLASSEXW window_class{sizeof(window_class)};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = Module();
    window_class.lpszClassName = L"ux.PlatformThread";
    return RegisterClassExW(&window_class);
  }();
  queue_->window = CreateWindowExW(0, MAKEINTATOM(atom), L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, Module(), nullptr);
}

PlatformThread::~PlatformThread() {
  HWND window;
  {
    std::lock_guard<std::mutex> lock(queue_->mutex);
    window = std::exchange(queue_->window, nullptr);
  }
  MSG message;
  while (PeekMessageW(&message, window, kRun, kRun, PM_REMOVE)) {
    delete reinterpret_cast<std::function<void()>*>(message.lParam);
  }
  DestroyWindow(window);
}

void PlatformThread::Post(const std::shared_ptr<Queue>& queue, std::function<void()> task) {
  auto* queued = new std::function<void()>(std::move(task));
  {
    std::lock_guard<std::mutex> lock(queue->mutex);
    if (queue->window != nullptr && PostMessageW(queue->window, kRun, 0, reinterpret_cast<LPARAM>(queued))) return;
  }
  delete queued;
}

LRESULT CALLBACK PlatformThread::WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kRun) return DefWindowProcW(window, message, wparam, lparam);
  std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(lparam));
  (*task)();
  return 0;
}

}  // namespace ux
