cmake_minimum_required(VERSION 3.10)
project(ux_keyboard)

add_library(ux_keyboard SHARED keyboard_bridge.c)
target_link_libraries(ux_keyboard log)

# 16KB page size support (required for Android 15+)
target_link_options(ux_keyboard PRIVATE "-Wl,-z,max-page-size=16384")
