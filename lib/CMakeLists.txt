# SPDX-License-Identifier: Apache-2.0

# ReSpeaker Lav custom libraries CMakeLists.txt

# Add Opus audio codec library
add_subdirectory_ifdef(CONFIG_OPUS_CODEC opus)

# Add SpeexDSP audio processing library
add_subdirectory_ifdef(CONFIG_SPEEXDSP speexdsp)

# Add Lua scripting language library
add_subdirectory_ifdef(CONFIG_LUA lua)
