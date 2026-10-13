cmake_minimum_required(VERSION 3.13)

project(libsmacker VERSION 1.2.0 LANGUAGES C)

# The autotools build (configure.ac / Makefile.am) stays the way to build and
# install the library. This file exists for the fuzzing harness: ./fuzz build
# configures it once per variant under fuzzer/build/<variant>/.

option(ENABLE_ASAN "Build the library with AddressSanitizer and UBSan" OFF)

set(LIBSRCS smacker.c)

add_library(smacker_static STATIC ${LIBSRCS})
target_include_directories(smacker_static PUBLIC ${CMAKE_SOURCE_DIR})
target_compile_options(smacker_static PRIVATE -Wall -Wextra)

if(ENABLE_ASAN)
    set(ASAN_C_FLAGS -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    target_compile_options(smacker_static PRIVATE ${ASAN_C_FLAGS})
    target_link_options(smacker_static PUBLIC ${ASAN_C_FLAGS})
endif()

add_subdirectory(src/fuzz)
