# The handler sources, built into ux_plugin and into windows/test.
set(UX_PLUGIN_SOURCES
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/url_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/url_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/url_detect.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/url_detect.h"
)

# The SDK headers declare only what Windows 10 1903 (build 18362) has.
set(UX_PLUGIN_DEFINITIONS
  _WIN32_WINNT=0x0A00
  NTDDI_VERSION=0x0A000007
)
