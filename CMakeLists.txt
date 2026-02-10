# SPDX-License-Identifier: Apache-2.0

# This is a Zephyr module/repository root CMakeLists.txt
# It provides custom drivers and libraries to applications

# Add include directory for custom headers (using Zephyr's mechanism)
zephyr_include_directories(include)

# Add custom libraries (including Opus codec)
add_subdirectory(lib)

# Add custom drivers
add_subdirectory(drivers)