#ifndef UX_COM_SCOPE_H_
#define UX_COM_SCOPE_H_

#include <windows.h>

namespace ux {

// COM on the calling thread while it lives, in the apartment the thread already
// has, if any.
class ComScope {
 public:
  ComScope() : initialized_(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {}
  ~ComScope() {
    if (initialized_) CoUninitialize();
  }

  ComScope(const ComScope&) = delete;
  ComScope& operator=(const ComScope&) = delete;

 private:
  const bool initialized_;
};

}  // namespace ux

#endif  // UX_COM_SCOPE_H_
