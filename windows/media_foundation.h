#ifndef UX_MEDIA_FOUNDATION_H_
#define UX_MEDIA_FOUNDATION_H_

#include <windows.h>

#include <memory>
#include <optional>
#include <type_traits>

namespace ux {

// Media Foundation, loaded and started for this object's life, on any thread.
// ux_plugin.dll delay-loads mfplat.dll, mfreadwrite.dll and mf.dll, which an N
// edition of Windows lacks without the Media Feature Pack, so a Media
// Foundation call runs only while one of these has started.
class MediaFoundation {
 public:
  MediaFoundation();
  ~MediaFoundation();

  MediaFoundation(const MediaFoundation&) = delete;
  MediaFoundation& operator=(const MediaFoundation&) = delete;

  // S_OK once started, the load error of a Media Foundation DLL that does not
  // load, or MFStartup's failure.
  HRESULT status() const { return status_; }

 private:
  struct FreeModule {
    void operator()(HMODULE module) const { FreeLibrary(module); }
  };
  using Module = std::unique_ptr<std::remove_pointer_t<HMODULE>, FreeModule>;

  Module platform_;
  Module read_write_;
  Module core_;
  HRESULT status_;
};

// COM's multithreaded apartment joined on the calling thread, and Media
// Foundation started, for this object's life: what Media Foundation work on a
// thread of its own needs.
class MediaWork {
 public:
  MediaWork();
  ~MediaWork();

  MediaWork(const MediaWork&) = delete;
  MediaWork& operator=(const MediaWork&) = delete;

  // S_OK once started, or why COM or Media Foundation did not start.
  HRESULT status() const { return media_ ? media_->status() : com_; }

 private:
  const HRESULT com_;
  // Started once the thread has joined the apartment.
  std::optional<MediaFoundation> media_;
};

}  // namespace ux

#endif  // UX_MEDIA_FOUNDATION_H_
