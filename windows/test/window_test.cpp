#include <windows.h>

#include <powerbase.h>

#include "../window_plugin.h"
#include "check.h"

namespace {

bool DisplayRequired() {
  EXECUTION_STATE state = 0;
  CHECK(CallNtPowerInformation(SystemExecutionState, nullptr, 0, &state, sizeof(state)) == 0);
  return (state & ES_DISPLAY_REQUIRED) != 0;
}

}  // namespace

void WindowSuite() {
  DWORD session = 0;
  ProcessIdToSessionId(GetCurrentProcessId(), &session);
  // Windows drops a display requirement in session 0, which has no display.
  if (session == 0) {
    check_skipped = "session 0 holds no display";
    return;
  }
  CHECK(!DisplayRequired());
  CHECK(ux::KeepAwake(true));
  CHECK(DisplayRequired());
  CHECK(ux::KeepAwake(false));
  CHECK(!DisplayRequired());
}
