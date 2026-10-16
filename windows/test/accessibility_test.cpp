#include <windows.h>

#include <winrt/Windows.UI.ViewManagement.h>

#include <cstdio>

#include "../accessibility_plugin.h"
#include "check.h"

void AccessibilitySuite() {
  CHECK(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)));
  // UISettings reads Animation effects through WinRT, apart from SystemParametersInfo.
  const bool animates = winrt::Windows::UI::ViewManagement::UISettings().AnimationsEnabled();
  std::printf("reduceMotion: %s\n", ux::ReducesMotion() ? "true" : "false");
  CHECK(ux::ReducesMotion() == !animates);
  CoUninitialize();
}
