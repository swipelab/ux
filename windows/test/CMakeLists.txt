# The native tests of ux's Windows plugin: the handler sources and the suites
# in ux_test.exe, over the Flutter SDK's C++ client wrapper. No host app builds
# this project; banlu's `tool/be.sh ctest` configures, builds and runs it.
cmake_minimum_required(VERSION 3.14)
project(ux_test LANGUAGES CXX)

set(FLUTTER_ROOT "" CACHE PATH "The Flutter SDK whose Windows engine artifacts the tests build against")
set(ENGINE "${FLUTTER_ROOT}/bin/cache/artifacts/engine/windows-x64")
if(NOT EXISTS "${ENGINE}/flutter_windows.dll.lib")
  message(FATAL_ERROR "no Windows engine artifacts in ${ENGINE}: pass -DFLUTTER_ROOT=<Flutter SDK>")
endif()
set(WRAPPER "${ENGINE}/cpp_client_wrapper")

include("${CMAKE_CURRENT_SOURCE_DIR}/../sources.cmake")

add_executable(ux_test
  "ux_test.cpp"
  "check.h"
  "file_types_test.cpp"
  "image_probe_test.cpp"
  "media_foundation_test.cpp"
  "platform_thread_test.cpp"
  "raster_test.cpp"
  "support.h"
  "url_detect_test.cpp"
  "video_export_test.cpp"
  ${UX_PLUGIN_SOURCES}
  "${WRAPPER}/core_implementations.cc"
  "${WRAPPER}/standard_codec.cc"
  "${WRAPPER}/plugin_registrar.cc"
)
target_compile_features(ux_test PRIVATE cxx_std_17)
target_compile_options(ux_test PRIVATE /W4 /WX /wd4100 /EHsc)
target_compile_definitions(ux_test PRIVATE UNICODE _UNICODE _HAS_EXCEPTIONS=0 "$<$<CONFIG:Debug>:_DEBUG>"
  ${UX_PLUGIN_DEFINITIONS})
target_include_directories(ux_test PRIVATE "${ENGINE}" "${WRAPPER}/include")
target_link_libraries(ux_test PRIVATE "${ENGINE}/flutter_windows.dll.lib" ${UX_PLUGIN_LIBRARIES} dxgi)
target_link_options(ux_test PRIVATE ${UX_PLUGIN_LINK_OPTIONS})
add_custom_command(TARGET ux_test POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${ENGINE}/flutter_windows.dll" "$<TARGET_FILE_DIR:ux_test>")

enable_testing()
add_test(NAME file_types COMMAND ux_test file_types)
add_test(NAME image_probe COMMAND ux_test image_probe)
add_test(NAME media_foundation COMMAND ux_test media_foundation)
add_test(NAME platform_thread COMMAND ux_test platform_thread)
add_test(NAME raster COMMAND ux_test raster)
add_test(NAME url_detect COMMAND ux_test url_detect)
add_test(NAME video_export COMMAND ux_test video_export)
