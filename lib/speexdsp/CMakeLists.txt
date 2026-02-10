# SPDX-License-Identifier: Apache-2.0
#
# SpeexDSP DSP library for Zephyr
# Configured for fixed-point embedded operation

zephyr_library_named(speexdsp)
zephyr_library_property(ALLOW_EMPTY TRUE)

# Include directories
zephyr_library_include_directories(
    speexdsp/include
)

# Expose public headers to the entire project
zephyr_include_directories_ifdef(CONFIG_SPEEXDSP
    speexdsp/include
)

# SpeexDSP source files - only compile if CONFIG_SPEEXDSP is enabled
zephyr_library_sources_ifdef(CONFIG_SPEEXDSP
    speexdsp/libspeexdsp/preprocess.c
    speexdsp/libspeexdsp/filterbank.c
    speexdsp/libspeexdsp/fftwrap.c
    speexdsp/libspeexdsp/mdf.c
    speexdsp/libspeexdsp/scal.c
    speexdsp/libspeexdsp/kiss_fft.c
    speexdsp/libspeexdsp/kiss_fftr.c
    speexdsp/libspeexdsp/smallft.c
)

# Private preprocessor defines for fixed-point operation
zephyr_compile_options_ifdef(CONFIG_SPEEXDSP
    -DFIXED_POINT=1
    -DUSE_KISS_FFT=1
    -DEXPORT=
    -DRANDOM_PREFIX=speex
    -D_USE_SSE=0
    -D_USE_NEON=0
)

# Compile options to suppress warnings from upstream code
zephyr_compile_options_ifdef(CONFIG_SPEEXDSP
    -Wno-sign-compare
    -Wno-maybe-uninitialized
    -Wno-double-promotion
    -Wno-unused-variable
)
