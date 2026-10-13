# libsmacker fuzzing checkout

This is libsmacker with an AFL++ campaign on top: `./fuzz` drives builds, the
campaign and triage (see `fuzzer/README.md`), and the harness is
`src/fuzz/main.c`. The library itself builds with autotools; the top-level
`CMakeLists.txt` exists only for the fuzzing builds. If the library ever
carries fuzzing-only patches, confirm any library bug on a clean upstream
tree before reporting it. Build scratch upstream trees under `./scratch`,
not the scratchpad.

## Crash triage

Turning an artifact or a sanitizer log into an `RA()`/`RF()` pair and a
`reportN.md`: use the `triage-crash` skill (`/triage-crash <artifact> [log]`).

## Builds

- Every build directory lives in `fuzzer/build/<variant>/` - the reproducers
  are `fuzzer/build/repro` (ASAN+UBSAN) and `fuzzer/build/repro-msan` (MSAN).
  Never create `build-repro*` or other build directories at the repository
  root.
- Reuse existing builds and rebuild incrementally
  (`cmake --build fuzzer/build/repro --target fuzz2`). Configure only when the
  directory is missing, through `./fuzz build <variant>`.

## Reports and issues

- Every reported bug keeps its `RA()` + `RF()` pair at the bottom of
  `src/fuzz/main.c`, tagged `/* reportN.md */`, with either the
  `gh issue create` comment or the issue URL above the `RF()`.
- Never run `gh issue create`: filing is the user's call. Always spell out
  `--repo greg-kennedy/libsmacker`.
- Once upstream fixes a bug, confirm that `tc<n>` passes, then delete its pair.
  A passing `tc<n>` is noise, not a test.
