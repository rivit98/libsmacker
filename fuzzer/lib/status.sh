# Campaign dashboard and health check - window 0 of the tmux session.
#
#   ./fuzz status            # print once
#   ./fuzz status --loop     # refresh every $REFRESH seconds (default 600)
#
# COVERAGE is what the instance has reached now, PREV-COV what it had reached
# at the run before this one - the pair is the progress the campaign made in
# between, which a single number never shows. Every run leaves its coverage in
# $OUT_DIR/.status_prev for the next one; with --loop that is one refresh, ten
# minutes by default.
#
# Two halves, and neither computes what the other already knows:
#
#   per instance   this file, from $OUT_DIR/*/fuzzer_stats directly (so it
#                  still works when an instance is wedged) - the table and the
#                  health checks, which afl-whatsup's summary does not print
#   campaign total afl-whatsup -d -s, verbatim - instances alive, execs, speed,
#                  coverage, corpus, crashes, hangs, cycles without finds


USAGE="usage: $PROG status [--loop]

  (no options)  print the table once
  --loop        refresh every \$REFRESH seconds (default 600 - ten minutes)

The per-instance table and the health checks come from
\$OUT_DIR/*/fuzzer_stats, read directly so they still work when an instance is
wedged; the campaign totals below them are afl-whatsup -d -s verbatim.
PREV-COV is each instance's COVERAGE as of the run before this one, so the pair
shows how far the edge map moved since - in --loop, over one refresh.
Thresholds: MIN_STABILITY, STALE_INSTANCE, STALE_FIND."
usage_guard "$@"

# Ten minutes: the dashboard is read at a glance, not watched, and PREV-COV is
# the coverage of one refresh ago - over a shorter step the two columns are the
# same number, since a campaign past its first hour moves the edge map slowly.
REFRESH="${REFRESH:-600}"

# Health thresholds - a line is flagged when it crosses one of these.
MIN_STABILITY="${MIN_STABILITY:-85}"     # %, below this the target is non-deterministic
STALE_INSTANCE="${STALE_INSTANCE:-120}"  # s since last fuzzer_stats update = dead
STALE_FIND="${STALE_FIND:-7200}"         # s without a new path = plateau

# The shared palette from common.sh, aliased to the short names this file uses.
c_red="$C_RED"; c_grn="$C_GRN"; c_yel="$C_YEL"; c_dim="$C_DIM"; c_off="$C_OFF"

stat_of() { sed -n "s/^$2 *: *//p" "$1" | head -1 | tr -d ' '; }

num() { local v="${1%%.*}"; v="${v//[^0-9-]/}"; echo "${v:-0}"; }

# bitmap_cvg is AFL's own coverage number: the share of the edge map this
# instance has reached. Per instance, not campaign-wide - the lanes sync, so
# they converge, and one lane sitting well below the others is the signal.
collect() {  # emits: name execs_ps coverage corpus crashes hangs stability cycles pending last_find_age last_update_age
  local now; now="$(date +%s)"
  local f
  for f in "$OUT_DIR"/*/fuzzer_stats; do
    [ -f "$f" ] || continue
    local name last_find last_update execs
    name="$(basename "$(dirname "$f")")"
    last_find="$(num "$(stat_of "$f" last_find)")"
    last_update="$(num "$(stat_of "$f" last_update)")"
    # AFL reports a nonsense execs_per_sec until the first second of real
    # fuzzing has elapsed; prefer the last-minute average once it exists.
    execs="$(num "$(stat_of "$f" execs_ps_last_min)")"
    if [ "$execs" -le 0 ]; then
      if [ $(( now - $(num "$(stat_of "$f" start_time)") )) -lt 90 ]; then
        execs=-1                                  # still calibrating: warmup
      else
        execs="$(num "$(stat_of "$f" execs_per_sec)")"
      fi
    fi
    printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
      "$name" \
      "$execs" \
      "$(stat_of "$f" bitmap_cvg | tr -d '%' | sed 's/^$/0/')" \
      "$(num "$(stat_of "$f" corpus_count)")" \
      "$(num "$(stat_of "$f" saved_crashes)")" \
      "$(num "$(stat_of "$f" saved_hangs)")" \
      "$(num "$(stat_of "$f" stability)")" \
      "$(num "$(stat_of "$f" cycles_done)")" \
      "$(num "$(stat_of "$f" pending_total)")" \
      "$([ "$last_find" -gt 0 ] && echo $(( now - last_find )) || echo -1)" \
      "$(( now - last_update ))"
  done
}

# Where the coverage of the last run is kept, so this one can print it beside
# the current one. Inside $OUT_DIR: the numbers describe that state directory
# and nothing else, and `./fuzz clean state` takes them with it. One file per
# campaign, so a `./fuzz status` run by hand while a dashboard loops moves the
# dashboard's baseline forward by one - the columns stay correct, the step just
# gets shorter for a frame.
PREV_FILE="${PREV_FILE:-$OUT_DIR/.status_prev}"

# name -> coverage at the previous run, and when that run was.
declare -A prev_cov=()
prev_at=0
load_prev() {
  local n c
  [ -f "$PREV_FILE" ] || return 0
  while read -r n c; do
    case "$n" in
      '#') prev_at="$(num "$c")" ;;
      '')  ;;
      *)   prev_cov[$n]="$c" ;;
    esac
  done < "$PREV_FILE"
  return 0
}

# This run's coverage, for the next one to read. Written to .tmp and renamed, so
# a dashboard killed mid-write leaves the last complete snapshot behind rather
# than half a file.
save_prev() { # save_prev <name> <coverage>...
  [ -d "$OUT_DIR" ] || return 0
  [ "$#" -gt 0 ] || return 0
  {
    printf '# %s\n' "$(date +%s)"
    while [ "$#" -gt 1 ]; do printf '%s %s\n' "$1" "$2"; shift 2; done
  } >"$PREV_FILE.tmp" 2>/dev/null && mv -- "$PREV_FILE.tmp" "$PREV_FILE" || return 0
}

print_report() {
  local warn=() n_inst=0 alive=0 snapshot=() pcov
  prev_cov=(); prev_at=0; load_prev

  echo "${c_dim}$(date '+%F %T')${c_off}  campaign ${TMUX_SESSION}   state: $OUT_DIR   TC: ${TC:-<all test cases>}"
  echo
  printf '%-10s %9s %8s %9s %8s %8s %7s %9s %7s %9s %11s\n' \
    INSTANCE EXEC/S COVERAGE PREV-COV CORPUS CRASHES HANGS STABILITY CYCLES PENDING LAST-FIND
  printf '%s\n' "------------------------------------------------------------------------------------------------------------"

  while read -r n e cov c cr h st cy pd lf lu; do
    n_inst=$((n_inst + 1))

    local mark="" color=""
    if [ "$lu" -gt "$STALE_INSTANCE" ]; then
      color="$c_red"; mark=" DEAD"; warn+=("$n: no fuzzer_stats update in $(human_age "$lu") - instance is dead or wedged")
    else
      alive=$((alive + 1))
      if [ "$st" -lt "$MIN_STABILITY" ]; then
        color="$c_yel"   # row is flagged yellow; no health line for it
      elif [ "$lf" -gt "$STALE_FIND" ] && [ "$cy" -gt 0 ] 2>/dev/null; then
        color="$c_dim"; warn+=("$n: no new path in $(human_age "$lf") - plateau, consider new seeds or a dictionary pass")
      fi
    fi
    [ "$cr" -gt 0 ] && color="${color:-$c_grn}"

    # PREV-COV formatted whole, % included: an instance this file has not seen
    # before - the first run, or a lane added since - has no previous coverage
    # and gets a dash, which no %-suffixed number could stand in for.
    if [ -n "${prev_cov[$n]:-}" ]; then pcov="${prev_cov[$n]}%"; else pcov="-"; fi
    snapshot+=("$n" "$cov")

    printf '%s%-10s %9s %7s%% %9s %8s %8s %7s %8s%% %7s %9s %11s%s%s\n' \
      "$color" "$n" "$([ "$e" -ge 0 ] && echo "$e" || echo warmup)" \
      "$cov" "$pcov" "$c" "$cr" "$h" "$st" "$cy" "$pd" "$(human_age "$lf")" "$mark" "$c_off"
  done < <(collect | sort)

  # After the table, so a run that dies while collecting leaves the previous
  # run's numbers as the baseline rather than replacing them with half a table.
  save_prev ${snapshot[@]+"${snapshot[@]}"}

  echo
  if [ "$n_inst" -eq 0 ]; then
    echo; echo "${c_yel}no instances yet - run ./fuzz run${c_off}"
  fi

  # Containers are the other half of "is it alive": a fuzzer_stats file keeps
  # its last values after the container behind it died.
  local n_ctr
  n_ctr="$(running_instances)"
  printf 'backend %s: %s instance(s) running\n' "$FUZZ_BACKEND" "$n_ctr"
  if [ "$n_inst" -gt 0 ] && [ "$n_ctr" -lt "$alive" ]; then
    warn+=("$((alive - n_ctr)) instance(s) have live stats but no process - a tab exited, check its tmux window")
  fi

  # Box health: the things that silently ruin a campaign.
  local load shm_free disk_free
  load="$(cut -d' ' -f1 /proc/loadavg)"
  shm_free="$(df -h /dev/shm --output=avail 2>/dev/null | tail -1 | tr -d ' ')"
  disk_free="$(df -h "$OUT_DIR" --output=avail 2>/dev/null | tail -1 | tr -d ' ')"
  echo; echo "${c_yel}health:${c_off}"
  printf '  - load %s (jobs %s)   /dev/shm free %s   state fs free %s\n' \
    "$load" "$JOBS" "${shm_free:-?}" "${disk_free:-?}"
  [ "${#warn[@]}" -gt 0 ] && printf '  - %s\n' "${warn[@]}"

  # Campaign totals come from afl-whatsup, never from adding these columns up:
  # instances alive, total execs, speed, coverage, corpus, crashes, hangs and
  # cycles without finds are all in its -s summary already, and a second
  # implementation of the same number is a second thing to keep correct. What
  # this file adds is what -s does not print: the per-instance table above and
  # the health checks below it.
  if [ "$n_inst" -gt 0 ]; then
    echo; echo "${c_dim}--- afl-whatsup -d -s ---${c_off}"
    local summary
    # -d (include dead fuzzers) is not optional here: afl-whatsup decides
    # liveness with kill -0 on fuzzer_pid, and in the docker backend every lane
    # is its own container, so a whatsup container sees none of those PIDs and
    # would skip every instance - a summary of zeros. Liveness is answered
    # above instead, by stale stats and running_instances.
    summary="$(afl_run -- "afl-whatsup -d -s $B_OUT_DIR" 2>/dev/null | sed -n '/Summary stats/,$p')"
    if [ -n "$summary" ]; then
      printf '%s\n' "$summary"
    else
      echo "${c_yel}afl-whatsup printed no summary - not installed in the backend?${c_off}"
    fi
  fi
}

# Draw a pre-rendered frame. The report is built into a string FIRST and only
# then painted, so the terminal never shows a half-finished screen (collecting
# it takes a second - afl-whatsup runs the backend). Painting overwrites in
# place rather than running clear(1): clearing first would blank the screen for
# that second and make the tab flicker on every tick.
#
# Overwriting only replaces as many characters as the new line has, so every
# line ends in erase-to-end-of-line (\033[K) - without it, a line that got
# shorter since the last tick keeps the tail of the old one. \033[J then clears
# the rows below a frame that got shorter.
paint() {
  local frame="$1"
  frame="${frame//$'\n'/$'\033[K\n'}"
  # Cursor home, frame, erase to end - as escapes, so there is no tput to find.
  printf '\033[H%s\033[K\n\033[J' "$frame"
}

case "${1:-}" in
  --loop)
    printf '\033[?25l'                                   # hide the cursor
    trap 'printf "\033[?25h"; exit 0' INT TERM EXIT      # ... and put it back
    clear
    while :; do
      frame="$(print_report; printf '\n%s' "${c_dim}refreshed $(date +%T), every $(human_age "$REFRESH") - this tab is a dashboard, Ctrl-C here kills no fuzzer${c_off}")"
      paint "$frame"
      sleep "$REFRESH"
    done ;;
  "") print_report ;;
  *) usage ;;
esac
