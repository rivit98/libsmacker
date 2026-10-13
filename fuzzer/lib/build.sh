# Build the harness variants, through whichever backend FUZZ_BACKEND resolves to.
#
#   ./fuzz build                  # every variant
#   ./fuzz build msan lsan        # only these
#   ./fuzz build --clean [...]    # wipe fuzzer/build first
#
# A variant that fails does not stop the others. The summary at the end lists
# what was built and what was not, and the exit status is non-zero if anything
# failed.
#
# src/fuzz/main.c is an LLVMFuzzerTestOneInput harness; afl-cc links its own
# libAFLDriver.a for it (that is what -fsanitize=fuzzer means on the link line
# of an AFL build - libFuzzer is gone from this repo).  src/fuzz/CMakeLists.txt
# leaves every instrumentation flag to the AFL_USE_* environment variables.
#
#   fast     no sanitizer          throughput lanes, catches SEGV/abort
#   asan     ASAN + UBSAN          full-check lanes; AFL_USE_UBSAN implies
#                                  -fno-sanitize-recover
#   cmplog   CMPLOG/RedQueen       handed to afl-fuzz -c, never fuzzed directly
#   msan     MSAN                  uninitialized reads, for triage
#   lsan     LSAN                  per-input leaks via __AFL_LEAK_CHECK()
#   laf      laf-intel             split compares, for the plans' laf lanes
#   sand-asan / sand-msan          SAND oracles: sanitizer, fork server, no
#                                  edge map - passed to afl-fuzz -w
#   cov      no engine, no san     coverage, built with plain clang
#   repro    no engine, asan+ubsan fuzz2: the RR()/RF() reproducer, -O0, plain clang
#   repro-msan  no engine, msan    fuzz2 again, for findings only MSAN reports

USAGE="usage: $PROG build [--clean] [<variant>...]

  <variant>...  build only these, e.g. ./fuzz build sand-msan
  --clean       wipe fuzzer/build/ first - also how you switch backends

With no variant every one is built: ${FUZZ_VARIANTS[*]}

Variant names are checked before anything builds, so a typo in the last one
does not cost the builds in front of it. A variant that fails does not stop the
rest; the summary at the end gives each one's time, size and binary, or its
exit status and log, and the command exits non-zero if any failed. Every build
tees its full output to fuzzer/build/<variant>/build.log."
usage_guard "$@"

require_backend

CMAKE_COMMON="-DENABLE_ASAN=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo"

build_variant() { # <name> <target> <extra cmake args> [env...] -> the build's exit status
  local name="$1" target="$2" extra="$3"; shift 3
  local hdir="$BUILD_ROOT/$name" bdir log rc
  bdir="$(cpath "$BUILD_ROOT/$name")"
  log="$hdir/build.log"

  ensure_dirs "$hdir"
  log_step "building '$name' ($target) -> $hdir"

  # Everything the build prints goes to the terminal AND to the variant's own
  # build.log: afl-cc's instrumentation notes and the sanitizer warnings are
  # the first thing worth reading when a lane behaves oddly later, and they
  # scroll away otherwise. PIPESTATUS, not $?, because tee is last in the pipe.
  set +e
  {
    echo "=== $(date '+%F %T')  variant=$name  target=$target  backend=$FUZZ_BACKEND"
    echo "=== env: $*"
    afl_run -n "$CONTAINER_PREFIX-build-$name" $(env_args "$@") -- "
      set -e
      if [ '$target' != fuzz ]; then
        # The coverage binary is the one thing that is deliberately NOT built
        # with afl-cc: it carries no engine and no instrumentation, so llvm-cov
        # measures the library, not AFL's edge counters.
        export CC=clang CXX=clang++
      else
        # afl-clang-fast and afl-clang-lto are the SAME binary as afl-cc - the
        # symlink name is how afl-cc is told which mode to use, and a plain
        # afl-cc means PCGUARD, not LTO. LTO is the one worth having here:
        # collision-free edge IDs instead of hashed ones, so two edges never
        # share a map slot and the fuzzer stops chasing phantom coverage.
        #
        # Whether LTO is usable is afl-cc own answer, not something to guess
        # from PATH: afl-cc has the lld path compiled in and reports it in
        # afl-cc -h, while the AFL++ image ships no bare ld.lld at all.
        # Override with FUZZ_CC_MODE=lto|fast.
        case \"\${FUZZ_CC_MODE:-auto}\" in
          lto)  CC=afl-clang-lto ;;
          fast) CC=afl-clang-fast ;;
          *)
            if afl-cc -h 2>&1 | grep -qE '\[LTO\].*AVAILABLE'; then
              CC=afl-clang-lto
            else
              CC=afl-clang-fast
            fi ;;
        esac
        export CC CXX=\${CC}++
      # LTO mode puts bitcode in the .o files, so the archiver should be the
      # LLVM one - afl-cc says as much in its own help: LTO often needs RANLIB
      # and AR settings outside of afl-cc.
      CMAKE_AR_ARGS=
      if [ \$CC = afl-clang-lto ] && command -v llvm-ar >/dev/null 2>&1; then
        export AR=llvm-ar RANLIB=llvm-ranlib
        CMAKE_AR_ARGS=\"-DCMAKE_AR=\$(command -v llvm-ar) -DCMAKE_RANLIB=\$(command -v llvm-ranlib)\"
      fi
    fi
      echo \"    compiler: \$CC\"
      cd $bdir
      cmake $CMAKE_COMMON \$CMAKE_AR_ARGS $extra $B_REPO >/dev/null
      cmake --build . --target $target -j\$(nproc)
    "
  } 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -ne 0 ]; then
    log_err "'$name' build failed (exit $rc) - full log: $log"
  else
    log_ok "$name built - log: $log"
  fi
  return "$rc"
}

build_one() { # <variant>
  case "$1" in
    fast)   build_variant fast   fuzz "" ;;
    asan)   build_variant asan   fuzz "" AFL_USE_ASAN=1 AFL_USE_UBSAN=1 ;;
    cmplog) build_variant cmplog fuzz "" AFL_LLVM_CMPLOG=1 ;;
    # MSAN is pinned to afl-clang-fast: built in LTO mode the binary links, but
    # its fork server dies with SIGSEGV on the first exec ("Fork server crashed
    # with signal 11") - MSAN's shadow setup and the LTO link path do not mix.
    msan)   build_variant msan   fuzz "" AFL_USE_MSAN=1 FUZZ_CC_MODE=fast ;;
    lsan)   build_variant lsan   fuzz "" AFL_USE_LSAN=1 ;;
    # laf-intel: multi-byte compares split into byte compares, so the edge map
    # sees partial progress on keywords and magic values CMPLOG does not solve.
    laf)    build_variant laf    fuzz "" AFL_LLVM_LAF_ALL=1 ;;
    # SAND oracles (docs/SAND.md): sanitizer builds with a fork server but no
    # edge instrumentation, handed to a native lane with -w. afl-fuzz re-runs
    # only selected inputs through them (AFL_SAN_ABSTRACTION, lib/common.sh),
    # so a lane keeps native speed and still gets ASAN/UBSAN/MSAN verdicts.
    sand-asan) build_variant sand-asan fuzz "" AFL_USE_ASAN=1 AFL_USE_UBSAN=1 AFL_LLVM_ONLY_FSRV=1 ;;
    sand-msan) build_variant sand-msan fuzz "" AFL_USE_MSAN=1 AFL_LLVM_ONLY_FSRV=1 FUZZ_CC_MODE=fast ;;
    cov)    build_variant cov    fuzz_cov "" ;;
    # -DENABLE_ASAN=ON matters: fuzz2 gets asan+ubsan from the fuzz CMakeLists
    # either way, but the LIBRARY only gets it here - and an uninstrumented
    # library has much smaller stack frames and unchecked accesses - an
    # overflow inside smacker.c would go unreported.
    repro)  build_variant repro  fuzz2    "-DENABLE_ASAN=ON" ;;
    # The MSAN reproducer, for findings ASAN cannot see. MSAN needs every C
    # translation unit instrumented, the library included, so the flag goes
    # into CMAKE_C_FLAGS and not only onto fuzz2 (FUZZ_REPRO_SANITIZER).
    # ENABLE_ASAN stays OFF because the two sanitizers cannot share a binary.
    repro-msan) build_variant repro-msan fuzz2 "-DFUZZ_REPRO_SANITIZER=memory '-DCMAKE_C_FLAGS=-fsanitize=memory -fsanitize-memory-track-origins=2 -fno-omit-frame-pointer'" ;;
  esac
}

# Arguments are checked before anything builds: a typo in the last name should
# not cost the twenty minutes of builds in front of it.
clean=0; variants=()
for arg in "$@"; do
  case "$arg" in
    --clean) clean=1 ;;
    *)
      known=0
      for v in "${FUZZ_VARIANTS[@]}"; do [ "$v" = "$arg" ] && known=1; done
      [ "$known" = 1 ] || die "unknown variant '$arg' (${FUZZ_VARIANTS[*]})"
      variants+=("$arg") ;;
  esac
done
[ "${#variants[@]}" -gt 0 ] || variants=("${FUZZ_VARIANTS[@]}")
[ "$clean" = 1 ] && rm -rf "$BUILD_ROOT"

declare -A rc_of took
for v in "${variants[@]}"; do
  start=$SECONDS
  rc=0; build_one "$v" || rc=$?
  rc_of[$v]=$rc
  took[$v]=$((SECONDS - start))
done

log_step "build summary"
failed=0
for v in "${variants[@]}"; do
  b="$(bin_of "$v")"
  if [ "${rc_of[$v]}" -eq 0 ] && [ -x "$b" ]; then
    log_ok "$(printf '%-10s built   %6s  %5s  %s' "$v" "$(human_age "${took[$v]}")" "$(du -h "$b" | cut -f1)" "$b")"
  else
    failed=$((failed + 1))
    reason="exit ${rc_of[$v]}"
    [ "${rc_of[$v]}" -eq 0 ] && reason="no binary"
    log_err "$(printf '%-10s FAILED  %6s  %-9s %s' "$v" "$(human_age "${took[$v]}")" "$reason" "$BUILD_ROOT/$v/build.log")"
  fi
done

[ "$failed" -eq 0 ] || die "$failed of ${#variants[@]} variant(s) failed"
exit 0
