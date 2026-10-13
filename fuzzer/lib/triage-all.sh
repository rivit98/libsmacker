# Replay every crash and hang of a campaign through `./fuzz triage`.
#
#   ./fuzz triage-all                   # the campaign's crashes, then its hangs
#   ./fuzz triage-all --with msan       # only the MSAN build
#   ./fuzz triage-all -j 16             # 16 replays at a time
#   ./fuzz triage-all --hang-limit 0    # every hang, not a sample
#   ./fuzz triage-all DIR...            # every file in DIR instead
#
# find lists the artifacts, xargs -P runs them: every replay is
# `./fuzz triage --with <variant> <artifact>` in a child process, so the
# sanitizer options, the log format and the atomic write live in triage.sh
# alone and cannot drift from a hand-run triage; the variant list and the log
# names come from common.sh, which both of them read. Nothing here reads a log,
# or even what a replay exited with: the logs in $TRIAGE_LOG_DIR - $LOG_DIR, or
# ${LOG_DIR}_<TC> with TC set - are the product, for whatever processes them
# afterwards. The status line counts replays, nothing else.
#
# One replay is one artifact under one variant. Not one artifact at a time:
# triage.sh replays an artifact's variants in parallel and then waits for all
# of them, so every artifact would cost its slowest variant - an MSAN run, or
# a hang that holds its core for the full --timeout - while the other cores sat
# idle. Handed to xargs one pair at a time, the replays keep every -j slot busy
# until the list runs out.
#
# Written for the machine that is fuzzing, next to a live campaign: every
# replay runs under nice -n 19, which leaves the lanes their CPU however many
# of them run. Under FUZZ_BACKEND=docker that nice level stays with the docker
# client and does not reach the container - lower -j there.
#
# Every log stays, whatever its replay did: sanitizer reports, crashes, leaks,
# timeouts, replays that failed to start - and the clean ones, which are the
# answer "this artifact does nothing under this sanitizer" and take a replay to
# get back. $TRIAGE_LOG_DIR is then the whole sweep, and what reads it decides
# what a clean log means. ./fuzz clean logs is what empties it.
#
# Resumable: triage.sh writes each log atomically, and a replay whose log is
# there is dropped before xargs starts, so an interrupted sweep continues where
# it stopped, and a sweep repeated after new crashes have landed replays only
# the new ones.

USAGE="usage: $PROG triage-all [-j N] [--with v1,v2] [--timeout S] [--hang-limit N] [DIR...]

  -j N            replays to run at once, xargs -P (default: \$JOBS, one per
                  physical core - $JOBS here)
  --with a,b      variants to replay (default: every built one of asan, msan,
                  lsan, fast)
  --timeout S     per-replay wall clock, passed to ./fuzz triage
  --hang-limit N  hangs to take per instance, evenly spaced through the sorted
                  directory (default: 5; 0 takes every hang)
  DIR...          triage every file in these directories instead of the
                  campaign's - a flat directory from ./fuzz grab, say. Taken in
                  full: --hang-limit applies only to a campaign's hangs/.

Replays every crash of \$OUT_DIR/<instance>/crashes, then a sample of every
\$OUT_DIR/<instance>/hangs, through ./fuzz triage - one artifact under one
variant per replay, -j replays at a time through xargs -P, each at nice -n 19
so a running campaign keeps its cores. FUZZ_GROUP picks the campaign, as everywhere else.

Prints one status line - replays done out of the total and the rate - rewritten
in place on a terminal and written once a minute to a file or a pipe. No
verdict: not even a count of what the replays reported. The logs are the
product, and reading them is another tool's job. They go to \$LOG_DIR, or to
\${LOG_DIR}_<TC> when TC is set - here: $TRIAGE_LOG_DIR. A replay whose log
exists is skipped before anything starts, so an interrupted sweep resumes.

Every replay leaves its log there, the clean ones (exit 0) included: nothing is
removed afterwards, and ./fuzz clean logs is what empties the directory.

A sample, not every hang, because a campaign saves far more hangs than crashes
(AFL++ stops at 512 per instance) and a replay of one costs the full timeout.
--hang-limit 0 when you want them all."
usage_guard "$@"

WITH=""; REPLAY_TIMEOUT=""; HANG_LIMIT=5; PAR="$JOBS"; DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j)           [ $# -ge 2 ] || usage; PAR="$2"; shift ;;
    --with)       [ $# -ge 2 ] || usage; WITH="$2"; shift ;;
    --timeout)    [ $# -ge 2 ] || usage; REPLAY_TIMEOUT="$2"; shift ;;
    --hang-limit) [ $# -ge 2 ] || usage; HANG_LIMIT="$2"; shift ;;
    -*) usage ;;
    *)  DIRS+=("$1") ;;
  esac
  shift
done
case "$HANG_LIMIT" in ''|*[!0-9]*) usage ;; esac
case "$PAR" in ''|0|*[!0-9]*) usage ;; esac

# Fail here rather than once per replay: every replay needs the same backend
# and the same builds. A typo in --with or a missing build is reported once,
# with every bad name, exactly as ./fuzz triage would report it.
require_backend
triage_select_variants "$WITH"
variants=("${TRIAGE_RUN[@]}")

# What ./fuzz triage gets besides --with and the artifact. An array, so an
# empty option never becomes an empty argument; the ${x[@]+...} guard keeps
# bash from tripping over an empty one under set -u.
pass=()
if [ -n "$REPLAY_TIMEOUT" ]; then pass+=(--timeout "$REPLAY_TIMEOUT"); fi

# Every input find reaches from its arguments, sorted. AFL writes a README.txt
# into crashes/ and hangs/, and it is not an input.
inputs() { # inputs <find start and depth/path arguments...>
  find "$@" -type f ! -name README.txt | sort
}

# At most --hang-limit entries per directory, evenly spaced through its sorted
# list, first one included. The pick is a function of the list alone, so a
# second sweep replays the same hangs instead of a different fifth of them -
# and the ones it already logged are then skipped for free.
sample_per_dir() {
  awk -v limit="$HANG_LIMIT" '
    { d = $0; sub(/\/[^\/]*$/, "", d)
      if (!(d in n)) order[++nd] = d
      f[d, ++n[d]] = $0 }
    END {
      for (i = 1; i <= nd; i++) {
        d = order[i]; c = n[d]
        k = (limit > 0 && c > limit) ? limit : c
        for (j = 0; j < k; j++) print f[d, int(j * c / k) + 1]
      }
    }'
}

# Crashes first, every one of them, then the hangs: the crashes are what a
# campaign is for, and a sweep interrupted halfway should have spent its hours
# on those.
artifacts=()
if [ "${#DIRS[@]}" -gt 0 ]; then
  for d in "${DIRS[@]}"; do
    need_dir "$d"
    mapfile -t files < <(inputs "$d" -mindepth 1 -maxdepth 1)
    [ "${#files[@]}" -gt 0 ] || { log_warn "no files in $d"; continue; }
    artifacts+=("${files[@]}")
  done
else
  need_dir "$OUT_DIR" "no campaign state for '$CAMPAIGN_NAME'"
  mapfile -t crashes < <(inputs "$OUT_DIR" -mindepth 3 -maxdepth 3 -path "$OUT_DIR/*/crashes/*")
  mapfile -t hangs < <(inputs "$OUT_DIR" -mindepth 3 -maxdepth 3 -path "$OUT_DIR/*/hangs/*" | sample_per_dir)
  log "${#crashes[@]} crash(es), ${#hangs[@]} hang(s) - at most $HANG_LIMIT per instance (--hang-limit, 0 = all)"
  artifacts=(${crashes[@]+"${crashes[@]}"} ${hangs[@]+"${hangs[@]}"})
fi
[ "${#artifacts[@]}" -gt 0 ] || die "nothing to triage"

# The replays as <variant> <artifact> pairs, artifact-major: every variant of
# the first crash, then of the next one, so the crashes still come before the
# hangs. A replay whose log is already there is dropped here rather than handed
# to ./fuzz triage, which would start and skip it anyway, so the counts below
# are the work that is left and resuming a sweep of thousands does not start
# thousands of ./fuzz processes that do nothing.
# On a terminal the scan counts along: over a flat directory of 160,000
# artifacts it takes two minutes before the first replay (artifacts_test_smk:
# 135 s, all of it this bash loop), which used to be two minutes of silence. A
# Ctrl-C meanwhile ends the counter's line before the script dies of it.
scan_tty=0
if [ -t 1 ]; then
  scan_tty=1
  trap 'printf "\n"; trap - INT; kill -INT $$' INT
  trap 'printf "\n"; trap - TERM; kill -TERM $$' TERM
fi
log "checking ${#artifacts[@]} artifact(s) x ${#variants[@]} variant(s) against $TRIAGE_LOG_DIR"
pairs=(); logged=0; prefix=""; i=0
for a in "${artifacts[@]}"; do
  i=$((i + 1))
  if [ "$scan_tty" = 1 ] && [ $((i % 1000)) -eq 0 ]; then
    printf '\r\033[K  checked %d/%d' "$i" "${#artifacts[@]}"
  fi
  triage_log_prefix prefix "$a"
  for v in "${variants[@]}"; do
    if [ -s "${prefix}__${v}.log" ]; then logged=$((logged + 1))
    else pairs+=("$v" "$a")
    fi
  done
done
if [ "$scan_tty" = 1 ]; then
  printf '\r\033[K'
  trap - INT TERM
fi

total=$(( ${#pairs[@]} / 2 ))
log "${#artifacts[@]} artifact(s) x ${#variants[@]} variant(s) (${variants[*]}): $total to replay, $logged already logged -> $TRIAGE_LOG_DIR"
[ "$total" -gt 0 ] || { log_ok "nothing left to replay"; exit 0; }
log "$PAR replay(s) at a time"

# Sets s to progress()'s status line, from its counters - bash scoping lets a
# function read the locals of the function that called it.
progress_line() {
  local el rate
  el=$((SECONDS - start)); [ "$el" -gt 0 ] || el=1
  rate=$((finished * 10 / el))                        # tenths of a replay a second
  s="replayed $finished/$total ($((finished * 100 / total))%), $((rate / 10)).$((rate % 10))/s"
}

# The last stage of the replay pipeline: counts the "@@triage <variant> <exit
# status>" line each ./fuzz triage prints under TRIAGE_PROGRESS - the line is
# counted, the variant and the status it carries are not - and keeps one status
# line instead of a line per replay: on a terminal rewritten in place at most
# once a second, and also when nothing finishes, so the rate keeps moving while
# every slot sits in a hang; to a file or a pipe once a minute. The last state
# always ends as a log line of its own. Anything else that reaches it - an
# error from a ./fuzz triage that failed to start - goes to stderr on a line of
# its own. A stage of the pipeline, so it is in the replays' process group and
# a Ctrl-C ends it with them.
progress() { # progress <total>
  local total="$1" finished=0 start=$SECONDS
  local line s now last=-1 printed=$SECONDS shown=0 tty=0 cols=80
  if [ -t 1 ]; then tty=1; cols="$(tput cols 2>/dev/null || echo 80)"; fi
  while :; do
    if IFS= read -r -t 1 line; then
      case "$line" in
        '@@triage '*)
          finished=$((finished + 1)) ;;
        *)
          if [ "$shown" = 1 ]; then printf '\r\033[K'; shown=0; fi
          printf '%s\n' "$line" >&2 ;;
      esac
    elif [ $? -le 128 ]; then
      break                                             # end of input: xargs is done
    fi
    now=$SECONDS
    [ "$now" != "$last" ] || continue
    last=$now
    progress_line
    if [ "$tty" = 1 ]; then
      printf '\r\033[K%s' "${s:0:$((cols - 1))}"; shown=1
    elif [ $((now - printed)) -ge 60 ]; then
      log "$s"; printed=$now
    fi
  done
  if [ "$shown" = 1 ]; then printf '\r\033[K'; fi
  progress_line
  log "$s"
}

# Job control, so the xargs pipeline runs in a process group of its own, and
# with it every replay: ./fuzz triage, its subshells, timeout and the target
# all stay in that group (triage.sh runs timeout with --foreground, which
# otherwise moves the target into a group of its own). A Ctrl-C at the terminal
# then reaches this script alone, and the trap below ends the whole group, the
# same way it does for a `kill -INT` or `kill -TERM` from elsewhere. It has to:
# a sweep is hours long and meant to be interrupted, and the replays do not end
# by themselves - they are background jobs of a non-interactive shell
# (triage.sh's), which have SIGINT set to ignore, so without this they would
# keep -j cores of a fuzzing machine busy for the full --timeout after the
# sweep is gone. (Under FUZZ_BACKEND=docker the replay is a container;
# signalling the docker client does not stop it.)
#
# One kill of the group rather than a walk of the process tree from xargs: a
# process stays in its group after its parent dies, and a replay xargs forks
# while the kill is on its way is in the group too. The walk found neither -
# measured at -j 4, a Ctrl-C returned the prompt while replays were still being
# started, seconds later, by ./fuzz triage processes the walk had missed.
set -m

# The process group of the replays, and what ends it. Leaves the .tmp logs of
# the replays in flight behind, which the next sweep replaces.
xpid=""; xpgid=""
on_signal() { # on_signal <exit status>
  trap - INT TERM
  [ -n "$xpgid" ] || [ -z "$xpid" ] || replay_group
  if [ -n "$xpgid" ]; then
    # SIGTERM, not SIGINT: triage.sh runs its replays as background jobs of a
    # non-interactive shell, and those have SIGINT set to ignore. Then SIGKILL
    # for whatever is still there a second later: nothing in the group needs
    # a clean exit, a killed replay leaves only its .tmp log.
    kill -TERM -- "-$xpgid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 -- "-$xpgid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL -- "-$xpgid" 2>/dev/null || true
  fi
  # progress()'s status line is still on the screen, unfinished: end it rather
  # than write over it, so it shows how far the sweep got.
  if [ -t 1 ]; then printf '\n'; fi
  log_warn "interrupted - run again to resume"
  exit "$1"
}

# Sets xpgid to the process group xargs runs in - never to this script's own,
# which the kill above would end along with the replays.
replay_group() {
  local g
  g="$(ps -o pgid= -p "$xpid" 2>/dev/null)" || return 0
  g="${g//[[:space:]]/}"
  [ -n "$g" ] && [ "$g" != "$(ps -o pgid= -p $$ | tr -d '[:space:]')" ] && xpgid="$g"
  return 0
}
trap 'on_signal 130' INT
# TERM too: with -j replays in flight, a sweep killed from elsewhere would
# otherwise leave all of them running to the full --timeout.
trap 'on_signal 143' TERM

# -n 2: each ./fuzz triage gets one pair appended, "--with <variant>
# <artifact>". -d '\n': a path may hold spaces, never a newline (AFL names do
# not, and a pair is two lines). A failing ./fuzz triage does not stop xargs:
# the rest of the list still runs, and the failures surface as its exit status.
# TRIAGE_PROGRESS=1: each ./fuzz triage reports its replay as one stdout line
# instead of printing "replaying ...", and 2>&1 sends whatever else the
# replays print through progress() too, which keeps it off the status line.
# $! is progress()'s pid now, which is in the same process group; wait still
# returns xargs' exit status, because under pipefail a pipeline's status is its
# last failing stage's, and progress() exits 0.
printf '%s\n' "${pairs[@]}" \
  | TRIAGE_PROGRESS=1 xargs -d '\n' -r -n 2 -P "$PAR" nice -n 19 "$REPO_DIR/fuzz" triage ${pass[@]+"${pass[@]}"} --with 2>&1 \
  | progress "$total" &
xpid=$!
replay_group
rc=0; wait "$xpid" || rc=$?

[ "$rc" -eq 0 ] || die "some ./fuzz triage runs failed (xargs exit $rc) - see above; re-running resumes"
log_ok "$total replay(s) done - the logs are in $TRIAGE_LOG_DIR"
