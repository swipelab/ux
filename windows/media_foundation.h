#ifndef UX_MEDIA_FOUNDATION_H_
#define UX_MEDIA_FOUNDATION_H_

#include <windows.h>

namespace ux {

// COM in the multithreaded apartment and Media Foundation, started on the
// calling thread for this object's life. ux_plugin.dll delay-loads Media
// Foundation, which an N edition of Windows lacks without the Media Feature
// Pack; there status() fails before any Media Foundation call can run.
class MediaFoundation {
 public:
  MediaFoundation();
  ~MediaFoundation();

  MediaFoundation(const MediaFoundation&) = delete;
  MediaFoundation& operator=(const MediaFoundation&) = delete;

  // S_OK once started, HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND) where Windows
  // has no Media Foundation, or the failure of starting COM or Media Foundation.
  HRESULT status() const { return status_; }

 private:
  HRESULT com_;
  HRESULT status_;
};

}  // namespace ux

#endif  // UX_MEDIA_FOUNDATION_H_
