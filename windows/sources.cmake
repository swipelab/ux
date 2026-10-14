# The handler sources, built into ux_plugin and into windows/test.
set(UX_PLUGIN_SOURCES
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/file_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/file_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/file_types.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/file_types.h"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe.h"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/platform_thread.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/platform_thread.h"
  "${CMAKE_CURRENT_LIST_DIR}/text.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/text.h"
  "${CMAKE_CURRENT_LIST_DIR}/url_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/url_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/url_detect.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/url_detect.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_device.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_device.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_instance.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_instance.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_surface.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_surface.h"
)

# The SDK libraries the handlers link.
set(UX_PLUGIN_LIBRARIES icu d3d11 mfplat mfuuid windowscodecs delayimp)

# Media Foundation loads at the first video `create`, since a Windows N edition
# lacks it without the Media Feature Pack.
set(UX_PLUGIN_LINK_OPTIONS /DELAYLOAD:mfplat.dll)

# The SDK headers declare only what Windows 10 1903 (build 18362) has.
set(UX_PLUGIN_DEFINITIONS
  _WIN32_WINNT=0x0A00
  NTDDI_VERSION=0x0A000007
)
