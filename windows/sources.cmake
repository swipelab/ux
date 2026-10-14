# The handler sources, built into ux_plugin and into windows/test.
set(UX_PLUGIN_SOURCES
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/file_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/file_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/file_types.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/file_types.h"
  "${CMAKE_CURRENT_LIST_DIR}/media_foundation.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/media_foundation.h"
  "${CMAKE_CURRENT_LIST_DIR}/method_args.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/method_args.h"
  "${CMAKE_CURRENT_LIST_DIR}/platform_thread.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/platform_thread.h"
  "${CMAKE_CURRENT_LIST_DIR}/raster.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/raster.h"
  "${CMAKE_CURRENT_LIST_DIR}/text.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/text.h"
  "${CMAKE_CURRENT_LIST_DIR}/url_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/url_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/url_detect.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/url_detect.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_device.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_device.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_export.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_export.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_exporter_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_exporter_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_instance.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_instance.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_player_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_reader.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_reader.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_surface.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_surface.h"
  "${CMAKE_CURRENT_LIST_DIR}/video_thumbnail.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/video_thumbnail.h"
)

# The SDK libraries the handlers link.
set(UX_PLUGIN_LIBRARIES icu d3d11 mfplat mfreadwrite mfuuid windowscodecs delayimp)

# MediaFoundation (media_foundation.cpp) loads Media Foundation's DLLs before
# any call into them, so ux_plugin.dll loads on an N edition of Windows, which
# lacks them without the Media Feature Pack.
set(UX_PLUGIN_LINK_OPTIONS /DELAYLOAD:mfplat.dll /DELAYLOAD:mfreadwrite.dll)

# The SDK headers declare only what Windows 10 1903 (build 18362) has, and no
# min or max macro.
set(UX_PLUGIN_DEFINITIONS
  _WIN32_WINNT=0x0A00
  NTDDI_VERSION=0x0A000007
  NOMINMAX
)
