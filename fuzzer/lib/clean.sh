# Remove what a campaign leaves behind. Nothing here is irreplaceable except
# `crashes` - everything else is rebuilt or re-derived by another command.
#
#   ./fuzz clean <target>...   # exactly these, of the current campaign
#   ./fuzz clean --all         # every target of every campaign, crashes included
#
# With no target nothing is removed: the usage is printed instead.
#
# A target named on its own is the current campaign's: $OUT_DIR and
# $CONTAINER_PREFIX follow FUZZ_GROUP (state/<group>, or state/all without
# one). --all is every campaign's - the whole of $CAMPAIGN_DIR/state, every
# group's crashes and containers - because a campaign run with FUZZ_GROUP=smk
# lives in state/smk, and an --all that followed FUZZ_GROUP removed state/all
# alone and left every grouped campaign behind, crashes and queues included.
#
# Targets:
#   builds     fuzzer/build/*            every variant, rebuilt by `build`
#   logs       $TRIAGE_LOG_DIR           triage replays: $LOG_DIR, or
#                                        ${LOG_DIR}_<TC> with TC set; --all
#                                        takes every one of them
#   state      $OUT_DIR                  the AFL queues - ends any resume
#   crashes    the crashes/ and hangs/ dirs inside $OUT_DIR  - FINDINGS
#   containers leftover $CONTAINER_PREFIX-* docker containers
#
# Seeds and coverage output are not targets.
# crashes before state: under --all, state takes every crash with it, and the
# crashes - the one target that is findings - should be what the log reports.
ALL_TARGETS=(builds logs crashes state containers)

USAGE="usage: $PROG clean --all | <target>...

  <target>...    exactly these, of the current campaign
  --all          every target of every campaign, crashes included

Targets:
  builds      fuzzer/build/*    every variant, rebuilt by 'build'
  logs        \$LOG_DIR          triage replays - \${LOG_DIR}_<TC> with TC set
  state       \$OUT_DIR          the AFL queues - ends any resume
  crashes     the crashes/ and hangs/ dirs inside \$OUT_DIR - FINDINGS
  containers  leftover $CONTAINER_PREFIX-* docker containers

Without a target nothing is removed. A target named on its own is the current
campaign's - FUZZ_GROUP picks it (state/<group>, or state/all without one), and
TC the logs; --all takes the logs of every TC and the state, crashes and
containers of every campaign. state and crashes
are refused while a campaign is running - with --all, while any campaign is.
Seeds and coverage output are not targets."
usage_guard "$@"

# Whether a target reaches every campaign (--all) or only the current one.
ALL=0
# Where every campaign's state is: $OUT_DIR is one directory of it (unless set
# by hand to somewhere else).
STATE_ROOT="$CAMPAIGN_DIR/state"

target_paths() { # paths a target owns, one per line
  case "$1" in
    builds)   echo "$BUILD_ROOT" ;;
    logs)
      echo "$TRIAGE_LOG_DIR"
      if [ "$ALL" = 1 ]; then
        for p in "$LOG_DIR" "$LOG_DIR"_*; do
          if [ -d "$p" ]; then echo "$p"; fi
        done
      fi ;;
    state)
      echo "$OUT_DIR"
      [ "$ALL" = 0 ] || echo "$STATE_ROOT" ;;
    crashes)
      if [ "$ALL" = 1 ]; then
        for p in "$OUT_DIR"/*/crashes "$OUT_DIR"/*/hangs \
                 "$STATE_ROOT"/*/*/crashes "$STATE_ROOT"/*/*/hangs; do
          if [ -d "$p" ]; then echo "$p"; fi
        done | sort -u
      else
        ls -d "$OUT_DIR"/*/crashes "$OUT_DIR"/*/hangs 2>/dev/null || true
      fi ;;
    containers) ;;   # not a path
  esac
}

# afl-fuzz instances that are alive: the current campaign's, or under --all
# those of any campaign, since --all removes the state of every one of them.
alive_instances() {
  local n
  if [ "$ALL" = 0 ]; then running_instances; return 0; fi
  if [ "$FUZZ_BACKEND" = docker ]; then
    docker ps -q "${CFILTER[@]}" 2>/dev/null | wc -l
  else
    n="$(pgrep -fc "afl-fuzz .*-o ($STATE_ROOT/|$OUT_DIR)" 2>/dev/null || true)"
    echo "${n:-0}"
  fi
}

clean_target() {
  local t="$1" p n
  case "$t" in
    containers)
      n="$(docker ps -aq "${CFILTER[@]}" 2>/dev/null | wc -l)"
      if [ "$n" -gt 0 ]; then
        docker rm -f $(docker ps -aq "${CFILTER[@]}") >/dev/null 2>&1 || true
        log_ok "removed $n container(s)"
      fi
      return 0 ;;
  esac

  local freed=0
  while IFS= read -r p; do
    [ -e "$p" ] || continue
    # Never let an unset variable turn this into `rm -rf /`.
    case "$p" in ""|"/"|"$HOME") die "refusing to remove '$p'" ;; esac
    freed=1
    rm -rf -- "$p"
  done < <(target_paths "$t")
  [ "$freed" = 1 ] && log_ok "cleaned $t" || log "$t: nothing to remove"
  return 0
}

targets=()
case "${1:-}" in
  --all)  ALL=1; targets=("${ALL_TARGETS[@]}") ;;
  "")     usage ;;   # nothing named, nothing removed
  -*)     usage ;;
  *)
    for t in "$@"; do
      found=0
      for known in "${ALL_TARGETS[@]}"; do [ "$t" = "$known" ] && found=1; done
      [ "$found" = 1 ] || die "unknown target '$t' (${ALL_TARGETS[*]})"
      targets+=("$t")
    done ;;
esac

# The containers a target means: the current campaign's, or under --all those
# of every campaign of this project - common.sh names them
# afl-<project>-<campaign>-*. docker ORs repeated name filters.
CFILTER=(--filter "name=^${CONTAINER_PREFIX}-")
[ "$ALL" = 0 ] || CFILTER+=(--filter "name=^afl-${PROJECT_NAME}-")

# Stop the user from deleting a queue out from under a running campaign.
for t in "${targets[@]}"; do
  case "$t" in
    state|crashes)
      [ "$(alive_instances)" -gt 0 ] && \
        die "a campaign is still running - ./fuzz stop first (or clean something else)" ;;
  esac
done

log "cleaning: ${targets[*]}"
for t in "${targets[@]}"; do clean_target "$t"; done

# state named on its own leaves the other campaigns' state where it is: say so,
# so it does not look like state clean could not reach.
if [ "$ALL" = 0 ]; then
  for t in "${targets[@]}"; do
    [ "$t" = state ] || continue
    others=""
    for d in "$STATE_ROOT"/*/; do
      if [ -d "$d" ]; then d="${d%/}"; others+="${others:+ }${d##*/}"; fi
    done
    [ -z "$others" ] || log "state of other campaigns left: $others - FUZZ_GROUP=<name> ./fuzz clean state, or ./fuzz clean --all"
  done
fi
