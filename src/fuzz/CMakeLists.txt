# ── fuzzing engine ────────────────────────────────────────────────────────────
# AFL++ is the only supported engine.
#
#   fuzz      the campaign binary. MUST be built with an afl-* compiler, which
#             is what -fsanitize=fuzzer on the link line means here: afl-cc
#             swaps it for its own libAFLDriver.a. It is EXCLUDE_FROM_ALL, so
#             only an explicit `--target fuzz` builds it - a plain-clang build
#             of everything would otherwise link the real libFuzzer runtime
#             behind that same flag. ./fuzz build is the supported way to
#             build it.
#   fuzz2     the RR/RF reproducer, plain compiler, asan+ubsan - or msan with
#             -DFUZZ_REPRO_SANITIZER=memory
#   fuzz_cov  coverage, plain compiler, no sanitizers
#
# Both are built -DREPRODUCER: neither has a fuzzing engine to supply main(),
# and they share the one in fuzz_utils.h - argv takes input files or a
# vc<n>/tc<n> test case name.
#
# On the AFL path this file adds no instrumentation flags of its own - not the
# engine's, not the sanitizers'. Both come from the environment:
#
#   AFL_USE_ASAN=1 AFL_USE_UBSAN=1  cmake --build . --target fuzz
#   AFL_USE_MSAN=1                  cmake --build . --target fuzz
#   AFL_USE_LSAN=1                  cmake --build . --target fuzz
#   AFL_LLVM_CMPLOG=1               cmake --build . --target fuzz
#
# fuzzer/lib/build.sh drives all of these.
set(FUZZ_AFL_DRIVER_LINK_OPTIONS -fsanitize=fuzzer)

# fuzz2's sanitizer. ASAN and MSAN cannot share a binary, so the MSAN
# reproducer is its own build tree (build.sh's repro-msan). MSAN also needs the
# library instrumented: repro-msan passes -fsanitize=memory in CMAKE_C_FLAGS.
set(FUZZ_REPRO_SANITIZER "address" CACHE STRING
    "fuzz2 sanitizer: address (asan+ubsan) or memory (msan)")
set_property(CACHE FUZZ_REPRO_SANITIZER PROPERTY STRINGS address memory)
if(FUZZ_REPRO_SANITIZER STREQUAL "address")
    set(FUZZ_SANITIZER_OPTIONS -fsanitize=address,undefined -fno-sanitize-recover=all)
elseif(FUZZ_REPRO_SANITIZER STREQUAL "memory")
    set(FUZZ_SANITIZER_OPTIONS -fsanitize=memory -fsanitize-memory-track-origins=2)
else()
    message(FATAL_ERROR "FUZZ_REPRO_SANITIZER must be address or memory, not '${FUZZ_REPRO_SANITIZER}'")
endif()

set(FUZZ_BASE_OPTIONS -g -O2 -fno-omit-frame-pointer)

# ── shared pieces ─────────────────────────────────────────────────────────────
set(FUZZ_DEFS _GNU_SOURCE)

set(FUZZ_LIBSRCS "")
foreach(_src ${LIBSRCS})
    list(APPEND FUZZ_LIBSRCS ${CMAKE_SOURCE_DIR}/${_src})
endforeach()

# fuzz_add_library(<name> [OPTIONS ...])
function(fuzz_add_library name)
    cmake_parse_arguments(A "" "" "OPTIONS" ${ARGN})

    add_library(${name} STATIC ${FUZZ_LIBSRCS})
    target_include_directories(${name} PUBLIC ${CMAKE_SOURCE_DIR})
    target_compile_options(${name} PRIVATE ${A_OPTIONS})
endfunction()

# fuzz_add_harness(<name> LIBRARY <lib> [OPTIONS ...] [LINK_OPTIONS ...])
function(fuzz_add_harness name)
    cmake_parse_arguments(A "" "LIBRARY" "OPTIONS;LINK_OPTIONS" ${ARGN})

    add_executable(${name} ${CMAKE_CURRENT_SOURCE_DIR}/main.c)

    set_target_properties(${name} PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    )

    target_compile_options(${name} PRIVATE ${A_OPTIONS})
    target_compile_definitions(${name} PRIVATE ${FUZZ_DEFS})
    target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

    target_link_libraries(${name} PRIVATE ${A_LIBRARY} ${CMAKE_DL_LIBS})
    target_link_options(${name} PRIVATE ${A_LINK_OPTIONS} -rdynamic)
endfunction()


# ── fuzz ──────────────────────────────────────────────────────────────────────
# The campaign binary. Instrumentation and sanitizers come from the AFL_USE_*
# environment variables (see above); this file adds none of its own.
#
# fuzz_quiet.h turns the library's stderr messages into a branch on VERBOSE,
# here only: fuzz2 and fuzz_cov keep the library's calls as written.
fuzz_add_library(smacker_afl OPTIONS ${FUZZ_BASE_OPTIONS}
    -include ${CMAKE_CURRENT_SOURCE_DIR}/fuzz_quiet.h)

fuzz_add_harness(fuzz
    LIBRARY      smacker_afl
    OPTIONS      ${FUZZ_BASE_OPTIONS}
    LINK_OPTIONS ${FUZZ_AFL_DRIVER_LINK_OPTIONS}
)

# Built on demand only - see the note at the top of this file.
set_target_properties(fuzz smacker_afl PROPERTIES EXCLUDE_FROM_ALL TRUE)

# ── fuzz2 ─────────────────────────────────────────────────────────────────────
# smacker_static, which -DENABLE_ASAN=ON instruments as well, so an overflow
# inside smacker.c is reported where it happens.
fuzz_add_harness(fuzz2
    LIBRARY      smacker_static
    OPTIONS      ${FUZZ_BASE_OPTIONS} ${FUZZ_SANITIZER_OPTIONS} -O0 -DREPRODUCER
    LINK_OPTIONS ${FUZZ_SANITIZER_OPTIONS}
)

# ── fuzz_cov ──────────────────────────────────────────────────────────────────
# Coverage build. No fuzzing engine and no sanitizers: -DREPRODUCER brings in
# the shared entry point, so this runs the corpus files given on the command
# line.
set(COV_C_FLAGS -fprofile-instr-generate -fcoverage-mapping)
set(COV_LIB_OPTIONS ${FUZZ_BASE_OPTIONS} ${COV_C_FLAGS})

fuzz_add_library(smacker_cov OPTIONS ${COV_LIB_OPTIONS})

fuzz_add_harness(fuzz_cov
    LIBRARY      smacker_cov
    OPTIONS      ${COV_LIB_OPTIONS} -DREPRODUCER
    LINK_OPTIONS ${COV_C_FLAGS}
)
