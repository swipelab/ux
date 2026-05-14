cmake_minimum_required(VERSION 3.10)
project(ux)

# C bridges (keyboard, sensor) + C++ shim (url_detect → android.util.Patterns via JNI).
add_library(ux SHARED
    keyboard_bridge.c
    sensor_bridge.c
    url_detect.cpp)

set_target_properties(ux PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

target_link_libraries(ux log)

# 16KB page size support (required for Android 15+)
target_link_options(ux PRIVATE "-Wl,-z,max-page-size=16384")
