# Coverage, through AFL++'s own cov-analysis.
#
#   ./fuzz coverage                     # source coverage over the campaign queue
#   ./fuzz coverage --corpus DIR        # ... over some other corpus
#   ./fuzz coverage --ignore REGEX      # drop files matching REGEX from the report
#   ./fuzz coverage --edges             # AFL-only edge coverage, no cov build
#   ./fuzz coverage --stability         # per-line non-deterministic hit counts
#   ./fuzz coverage --search FILE:LINE  # which corpus entries reach that line
#
# Why there is still a clang-instrumented build:
#
#   AFL's own instrumentation is an edge bitmap - hashed (or with LTO,
#   collision-free) edge IDs and hit counts. It can tell you how much of the
#   map is covered, never which source line was missed. Source-level coverage
#   needs -fprofile-instr-generate, and AFL++'s cov-analysis shells out to
#   llvm-profdata/llvm-cov exactly like everyone else. So: the report is AFL's
#   tooling end to end, the instrumentation underneath it is llvm's.
#
#   --edges is the part that needs no coverage build at all: afl-showmap -C
#   over a corpus, using the campaign's own fast binary. Good for "is this
#   corpus still gaining edges", useless for "which function never ran".
#
# cov-analysis produces summary.txt, gaps.txt (the uncovered-region inventory),
# HTML, text, JSON and the merged profdata under $CAMPAIGN_DIR/cov.
#
# --stability needs gawk, which the stock AFL++ image does not ship; it works
# on a host backend with gawk installed.

USAGE="usage: $PROG coverage [--corpus DIR] [--ignore REGEX] [--edges|--stability|--search FILE:LINE]

  (no options)         cov-analysis report over the campaign queue
  --corpus DIR         measure some other corpus
  --ignore REGEX       drop matching files from the report (off by default)
  --edges              afl-showmap -C: AFL-only edge coverage, no cov build
  --stability          per-line non-deterministic hit counts (needs gawk)
  --search FILE:LINE   which corpus entries reach that line

The report is summary.txt, gaps.txt (uncovered regions by size), HTML, text,
JSON and the merged profdata under \$CAMPAIGN_DIR/cov. To drop the harness:
--ignore 'src/fuzz/'"
usage_guard "$@"

require_backend

MODE=report; CORPUS=""; IGNORE_RE=""; SEARCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --corpus)    CORPUS="$2"; shift ;;
    --ignore)    IGNORE_RE="$2"; shift ;;
    --edges)     MODE=edges ;;
    --stability) MODE=stability ;;
    --search)    MODE=search; SEARCH="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

# Default target: the live campaign queue if there is one, else the seeds.
if [ -z "$CORPUS" ]; then
  if [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then CORPUS="$OUT_DIR"; else CORPUS="$SEED_DIR"; fi
fi
need_dir "$CORPUS" "no corpus"

COV_OUT="$CAMPAIGN_DIR/cov"
B_CORPUS="$(cpath "$CORPUS")"
B_COV_OUT="$(cpath "$COV_OUT")"
B_BIN_COV="$(cpath "$BIN_COV")"

if [ "$MODE" = edges ]; then
  # Pure AFL: no coverage build, no llvm. Edge counts only.
  need_bin fast >/dev/null
  log "afl-showmap -C over $CORPUS ($(find "$CORPUS" -type f | wc -l) files)"
  afl_run -n "$CONTAINER_PREFIX-edges" $(env_args "${AFL_ENV[@]}" "${SAN_ENV[@]}") -- \
    "afl-showmap -C -i $B_CORPUS -o /dev/null -m none -t $TIMEOUT_FAST -- $B_BIN_FAST @@ 2>&1 | tail -12"
  exit 0
fi

need_bin cov >/dev/null

case "$MODE" in
  # Neither of these writes a report directory - they print and exit.
  stability)
    afl_run -n "$CONTAINER_PREFIX-cov-stability" $(env_args "TC=") -- \
      "cov-analysis stability -d $B_CORPUS -e '$B_BIN_COV @@' -t $JOBS" ;;
  search)
    [ -n "$SEARCH" ] || die "--search needs FILE:LINE"
    afl_run -n "$CONTAINER_PREFIX-cov-search" $(env_args "TC=") -- \
      "cov-analysis search $SEARCH -d $B_CORPUS -e '$B_BIN_COV @@' -t $JOBS" ;;
  report)
    IGNORE_ARG=""
    [ -n "$IGNORE_RE" ] && IGNORE_ARG="--ignore-regex '$IGNORE_RE'"
    # cov-analysis owns its report directory and refuses to touch one it did
    # not create. Clear the leftovers of the old hand-rolled llvm-cov pipeline
    # (raw profiles only - nothing else is ever removed here).
    if [ -d "$COV_OUT" ] && [ ! -f "$COV_OUT/.cov-analysis-report" ]; then
      rm -f "$COV_OUT"/*.profraw "$COV_OUT"/merged.profdata
      rmdir "$COV_OUT" 2>/dev/null || true
    fi
    log "$CORPUS -> $COV_OUT"
    afl_run -n "$CONTAINER_PREFIX-cov" $(env_args "TC=") -- \
      "cov-analysis report -d $B_CORPUS -e '$B_BIN_COV @@' -o $B_COV_OUT -t $JOBS $IGNORE_ARG"
    # lcov.info keeps working for anything that consumes it (CI, editors).
    # llvm-cov is resolved in the backend, the same way cov-analysis resolves
    # it - a hardcoded llvm-cov-20 only ever worked in one docker image.
    [ -f "$COV_OUT/coverage.profdata" ] && afl_run -- \
      "$LLVM_TOOL_FN
       llvm_cov=\$(find_llvm_tool llvm-cov) || { echo 'no llvm-cov in the backend - see Requirements in fuzzer/README.md' >&2; exit 1; }
       \$llvm_cov export $B_BIN_COV -instr-profile=$B_COV_OUT/coverage.profdata -format=lcov \
         ${IGNORE_RE:+-ignore-filename-regex='$IGNORE_RE'} > $(cpath "$REPO_DIR/lcov.info")" \
      && log_ok "lcov.info written"
    ;;
esac
