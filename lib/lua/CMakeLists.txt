# SPDX-License-Identifier: Apache-2.0
#
# Lua 5.5.0 library for Zephyr RTOS
# Configured for embedded operation

zephyr_library_named(lua)
zephyr_library_property(ALLOW_EMPTY TRUE)

# Include directories (public headers in lua/ directory for application access)
zephyr_library_include_directories(
    lua
)

# Expose public headers to the entire project
zephyr_include_directories_ifdef(CONFIG_LUA
    lua
)

# Lua core source files
zephyr_library_sources_ifdef(CONFIG_LUA
    lua/lapi.c
    lua/lcode.c
    lua/lctype.c
    lua/ldebug.c
    lua/ldo.c
    lua/ldump.c
    lua/lfunc.c
    lua/lgc.c
    lua/llex.c
    lua/lmem.c
    lua/lobject.c
    lua/lopcodes.c
    lua/lparser.c
    lua/lstate.c
    lua/lstring.c
    lua/ltable.c
    lua/ltm.c
    lua/lundump.c
    lua/lvm.c
    lua/lzio.c

    # Lua standard libraries
    lua/lbaselib.c
    lua/lcorolib.c
    lua/ldblib.c
    lua/liolib.c
    lua/lmathlib.c
    lua/loadlib.c
    lua/loslib.c
    lua/lstrlib.c
    lua/ltablib.c
    lua/lutf8lib.c
    lua/linit.c

    # Lua auxiliary library
    lua/lauxlib.c
)

# Private preprocessor defines for embedded Lua
zephyr_compile_options_ifdef(CONFIG_LUA
    # Undefine POSIX/DLOPEN to use standard C functions instead of POSIX ones
    -ULUA_USE_POSIX
    -ULUA_USE_DLOPEN
    -DLUA_USE_APICHECK=0
    -DLUA_COMPAT_5_3=1
)

# Compile options to suppress warnings from upstream code
zephyr_compile_options_ifdef(CONFIG_LUA
    -Wno-sign-compare
    -Wno-unused-variable
    -Wno-unused-parameter
    -Wno-old-style-declaration
    -Wno-missing-prototypes
)
