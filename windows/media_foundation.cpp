#include "media_foundation.h"

#include <mfapi.h>

namespace ux {

namespace {

// The application's directory, the DLL directories it set, then System32:
// never the working directory or PATH. The delay-loaded calls then bind to the
// module loaded here.
constexpr DWORD kSearch = LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;

}  // namespace

MediaFoundation::MediaFoundation()
    : platform_(LoadLibraryExW(L"mfplat.dll", nullptr, kSearch)),
      read_write_(platform_ ? LoadLibraryExW(L"mfreadwrite.dll", nullptr, kSearch) : nullptr),
      core_(read_write_ ? LoadLibraryExW(L"mf.dll", nullptr, kSearch) : nullptr),
      status_(core_ ? MFStartup(MF_VERSION, MFSTARTUP_LITE) : HRESULT_FROM_WIN32(GetLastError())) {}

MediaFoundation::~MediaFoundation() {
  if (SUCCEEDED(status_)) MFShutdown();
}

MediaWork::MediaWork() : com_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {
  if (SUCCEEDED(com_)) media_.emplace();
}

MediaWork::~MediaWork() {
  media_.reset();
  if (SUCCEEDED(com_)) CoUninitialize();
}

}  // namespace ux
