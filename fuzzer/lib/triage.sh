# Replay one artifact through the sanitizer builds, one log per build. The
# command prints progress only - it reaches no verdict about what the replays
# reported. The logs in $TRIAGE_LOG_DIR are the product: reading them is
# the triage-crash skill's job, and ./fuzz triage-all sweeps a whole campaign into
# them for whatever processes them afterwards.
#
#   ./fuzz triage <artifact>                     # every built variant
#   ./fuzz triage --with asan,msan <artifact>    # only these
#   ./fuzz triage --timeout 300 <artifact>       # per-replay limit (default: 20 s)
#
# The artifact is always the last argument: a crash, a hang, or any input file.
#
# An artifact is replayed under every sanitizer, not just the one that found
# it: the lane that saved it is whichever lane happened to hit the input first,
# and the same input often reports differently (or not at all) under another
# sanitizer.
#
# Only asan, msan, lsan and fast are replayed by default: cmplog exists to be
# passed to afl-fuzz -c, cov and laf carry no sanitizer, and the sand-* oracles
# are asan/msan without an edge map.
#
# Log: $TRIAGE_LOG_DIR/[<lane>__]<artifact>__<variant>.log - the directory is
# $LOG_DIR, or ${LOG_DIR}_<TC> when TC is set (logs/, logs_test_smk/), the
# lane only for an artifact that sits in a campaign's
# <lane>/{crashes,hangs,queue}/ - each one headed by the artifact path, the
# variant and the sanitizer options it ran with. A log is written to .tmp and
# renamed when the replay finishes, and a variant whose log is already there is
# skipped, so a sweep over thousands of artifacts resumes exactly.
#
# VERBOSE, when set, reaches the harness: the log then also shows
# "=== Running <test> ===" before each test case (for a hang, the last Running
# line is the test case that hangs) and libsmacker's own error messages, which
# the harness otherwise discards.
#
# TRIAGE_PROGRESS, when set (triage-all sets it), trades the "replaying ..."
# lines for one "@@triage <variant> <exit status>" line per replay on stdout -
# "logged" instead of the status for a variant whose log was already there -
# which triage-all counts into its status line.

USAGE="usage: $PROG triage [--with v1,v2] [--timeout S] <artifact>

  <artifact>    the file to replay - a crash, a hang, any input; always last
  --with a,b    only these variants, each of which must be built already
                (default: every built one of the four)
  --timeout S   per-replay wall clock, default 20 s
                (each replay also runs with a 4 MB stack: ulimit -s 4096)

Replays the artifact through asan, msan, lsan and fast at once, one log per
variant, and prints only what it is replaying: no verdict is reached here.
cmplog, cov, laf and the sand-* oracles are not replayed by default - cmplog
exists for afl-fuzz -c, cov and laf carry no sanitizer, and the oracles are
asan/msan without an edge map.

Full output per replay:
<logs>/[<lane>__]<artifact>__<variant>.log - <logs> is \$LOG_DIR, or
\${LOG_DIR}_<TC> when TC is set (here: $TRIAGE_LOG_DIR), the <lane>__ prefix
only for an artifact inside a campaign's <lane>/{crashes,hangs,queue}/, whose
name is unique only there. A variant whose log already exists is skipped. With
VERBOSE set the log also names each test case as it runs - the way to tell
which test case a hang is stuck in - and keeps libsmacker's own messages,
which are otherwise discarded.

Every crash and hang of a campaign, every variant of each replayed in
parallel: ./fuzz triage-all"
usage_guard "$@"

require_backend

ONLY=""; REPLAY_TIMEOUT=20
# Stack limit of every replay, in KiB: a stack-overflow finding depends on it.
REPLAY_STACK_KB=2048
while [ $# -gt 1 ]; do
  case "$1" in
    --with)    ONLY="$2"; shift ;;
    --timeout) REPLAY_TIMEOUT="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
[ $# -eq 1 ] || usage
artifact="$1"
[ -f "$artifact" ] || die "no such file: $artifact"

# Reporting-mode sanitizer options: symbolized frames, stack traces, and the
# signal handlers owned by the sanitizer rather than by AFL.
triage_env_for() {
  case "$1" in
    msan) echo "MSAN_OPTIONS=abort_on_error=1:symbolize=1:halt_on_error=1:print_stats=0" ;;
    lsan) echo "LSAN_OPTIONS=detect_leaks=1:symbolize=1:malloc_context_size=30" ;;
    # detect_leaks=1: ASAN carries LeakSanitizer, and a replay is one input in
    # a process that exits right after it, so the at-exit leak check is exact
    # here - unlike the persistent-mode campaign lanes, where SAN_ENV keeps it
    # off. A memory error still aborts first; a leak alone aborts at exit
    # (abort_on_error) after a "SUMMARY: AddressSanitizer: N byte(s) leaked"
    # line in the log.
    *)    echo "ASAN_OPTIONS=abort_on_error=1:symbolize=1:print_stacktrace=1:detect_leaks=1:allocator_may_return_null=1" ;;
  esac
}

# Which variants to run: the requested ones, or every built one
# (common.sh, shared with triage-all).
triage_select_variants "$ONLY"
variants=("${TRIAGE_RUN[@]}")

ensure_dirs "$TRIAGE_LOG_DIR"

# One replay: artifact x variant -> its log.
replay_one() { # replay_one <variant> <logfile>
  local v="$1" log_file="$2" san_env rc
  san_env="$(triage_env_for "$v")"
  {
    echo "### artifact : $artifact"
    echo "### variant  : $v ($(bin_of "$v"))"
    echo "### options  : $san_env"
    echo "###"
    # timeout's own exit status, not the container's: 124 means the replay hung
    # (a deep-recursion input under MSAN, a loop that never ends), and a log
    # that just stops is indistinguishable from a clean run otherwise.
    # The subshell matters: a replay that aborts makes the shell that reaped it
    # print "Aborted (core dumped)". Inside ( ) that notice goes to the log
    # with everything else instead of onto the terminal.
    # `|| rc=$?`, not `rc=$?` on the next line: these scripts run with set -e,
    # which would end the function at the failing replay - exactly the case
    # whose exit status matters.
    # VERBOSE only when set (the harness treats even an empty one as on):
    # afl_run strips it from the host environment, so it is passed explicitly.
    # %q: afl_run hands the command to bash -c, and an AFL name can carry shell
    # syntax - op:(null) made bash reject the line, and the log held only its
    # syntax error with exit 2.
    # --foreground: without it timeout moves the target into a process group of
    # its own, out of reach of triage-all, which stops a sweep by killing the
    # one group all its replays share. The target starts no children, so what
    # --foreground gives up - timing those out as well - costs nothing here.
    # ulimit -s: every replay runs with a 4 MB stack, whatever the host or the
    # container defaults to (usually 8 MB), so a deep-recursion input crashes
    # the same way on every machine. Only lowered, never raised: that is
    # always allowed.
    rc=0
    ( afl_run $(env_args "$san_env" \
                         "UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1:symbolize=1" \
                         "TC=${TC:-}" \
                         ${VERBOSE+"VERBOSE=$VERBOSE"}) -- \
        "ulimit -s $REPLAY_STACK_KB && timeout --foreground $REPLAY_TIMEOUT $(printf '%q %q' "$(cpath "$(bin_of "$v")")" "$(cpath "$artifact")")" ) 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && echo "### TIMED OUT after ${REPLAY_TIMEOUT}s"
    echo "### exit: $rc"
  } >"$log_file.tmp"
  # Only a finished replay gets the final name. A killed one (Ctrl-C in a long
  # sweep, the machine going down) leaves .tmp behind, so the "log is there,
  # skip it" rule above never mistakes half a report for a complete one.
  mv -- "$log_file.tmp" "$log_file"
  # Under triage-all: the replay, finished, as one line for its status line.
  if [ -n "${TRIAGE_PROGRESS:-}" ]; then printf '@@triage %s %s\n' "$v" "$rc"; fi
}

# The log paths, TC directory and lane included, come from common.sh: triage-all
# computes the same ones to skip what is already logged without starting a
# ./fuzz triage for it.
log_prefix=""; triage_log_prefix log_prefix "$artifact"

for v in "${variants[@]}"; do
  if [ -s "${log_prefix}__${v}.log" ]; then
    if [ -n "${TRIAGE_PROGRESS:-}" ]; then printf '@@triage %s logged\n' "$v"
    else log "$(basename "$artifact"): ${v} already logged"
    fi
  else
    [ -n "${TRIAGE_PROGRESS:-}" ] || log "replaying $(basename "$artifact") through: ${v}"
    replay_one "$v" "${log_prefix}__${v}.log" &
  fi
done
wait

