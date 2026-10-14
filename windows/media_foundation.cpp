#include "media_foundation.h"

#include <mfapi.h>

namespace ux {

namespace {

bool Installed() {
  static const bool installed = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) != nullptr &&
                                LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) != nullptr;
  return installed;
}

}  // namespace

MediaFoundation::MediaFoundation() : com_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {
  if (FAILED(com_)) {
    status_ = com_;
  } else if (!Installed()) {
    status_ = HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
  } else {
    status_ = MFStartup(MF_VERSION, MFSTARTUP_LITE);
  }
}

MediaFoundation::~MediaFoundation() {
  if (SUCCEEDED(status_)) MFShutdown();
  if (SUCCEEDED(com_)) CoUninitialize();
}

}  // namespace ux
