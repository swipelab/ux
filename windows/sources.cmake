# The handler sources, built into ux_plugin and into windows/test.
set(UX_PLUGIN_SOURCES
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/x_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/aes_ctr.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/aes_ctr.h"
  "${CMAKE_CURRENT_LIST_DIR}/camera_devices.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/camera_devices.h"
  "${CMAKE_CURRENT_LIST_DIR}/camera_instance.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/camera_instance.h"
  "${CMAKE_CURRENT_LIST_DIR}/camera_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/camera_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/camera_texture.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/camera_texture.h"
  "${CMAKE_CURRENT_LIST_DIR}/clipboard_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/clipboard_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/crypto_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/crypto_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/dib.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/dib.h"
  "${CMAKE_CURRENT_LIST_DIR}/drop_data.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/drop_data.h"
  "${CMAKE_CURRENT_LIST_DIR}/drop_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/drop_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/file_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/file_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/file_types.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/file_types.h"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe.h"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/image_probe_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/notifications_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/notifications_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/platform_thread.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/platform_thread.h"
  "${CMAKE_CURRENT_LIST_DIR}/text.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/text.h"
  "${CMAKE_CURRENT_LIST_DIR}/toast.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/toast.h"
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
  "${CMAKE_CURRENT_LIST_DIR}/wic.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/wic.h"
  "${CMAKE_CURRENT_LIST_DIR}/window_plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/window_plugin.h"
  "${CMAKE_CURRENT_LIST_DIR}/work_queue.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/work_queue.h"
)

# The SDK libraries the handlers link.
set(UX_PLUGIN_LIBRARIES bcrypt icu d3d11 mfplat mfuuid windowscodecs runtimeobject delayimp)

# Media Foundation loads at the first video `create`, since a Windows N edition
# lacks it without the Media Feature Pack.
set(UX_PLUGIN_LINK_OPTIONS /DELAYLOAD:mfplat.dll)

# The SDK headers declare only what Windows 10 1903 (build 18362) has.
set(UX_PLUGIN_DEFINITIONS
  _WIN32_WINNT=0x0A00
  NTDDI_VERSION=0x0A000007
)

# mf.dll, whose device sources and transcode types the camera calls, loads with
# CameraFoundation (camera_devices.cpp) before any call into it, since a
# Windows N edition lacks it without the Media Feature Pack.
list(APPEND UX_PLUGIN_LIBRARIES mf)
list(APPEND UX_PLUGIN_LINK_OPTIONS /DELAYLOAD:mf.dll)
