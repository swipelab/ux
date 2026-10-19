cmake_minimum_required(VERSION 3.14)
project(ux LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)

# Flutter links the target ${PROJECT_NAME}_plugin into the app and bundles it.
set(PLUGIN_NAME "ux_plugin")

include("${CMAKE_CURRENT_SOURCE_DIR}/sources.cmake")

add_library(${PLUGIN_NAME} SHARED
  "include/ux/x_plugin_c_api.h"
  "x_plugin_c_api.cpp"
  ${UX_PLUGIN_SOURCES}
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL ${UX_PLUGIN_DEFINITIONS})
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin ${UX_PLUGIN_LIBRARIES})
target_link_options(${PLUGIN_NAME} PRIVATE ${UX_PLUGIN_LINK_OPTIONS})

set(ux_bundled_libraries "" PARENT_SCOPE)
