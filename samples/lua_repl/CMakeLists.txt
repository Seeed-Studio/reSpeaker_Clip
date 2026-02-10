cmake_minimum_required(VERSION 3.20)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(lua_repl)

target_sources(app PRIVATE
	src/main.c
	src/posix_stubs.c
)
