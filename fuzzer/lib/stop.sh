# Stop the campaign: SIGINT every instance container (so each one flushes its
# stats and the primary does its AFL_FINAL_SYNC import), then drop the session.
#
#   ./fuzz stop              # graceful
#   ./fuzz stop --keep-tmux  # stop the fuzzers, leave the session for reading
#   ./fuzz stop --force      # SIGKILL anything still alive


USAGE="usage: $PROG stop [--keep-tmux] [--force]

  (no options)  SIGINT every instance, then drop the tmux session
  --keep-tmux   stop the fuzzers, leave the session for reading
  --force       SIGKILL whatever is still alive after 30 s

SIGINT first so the primary flushes its AFL_FINAL_SYNC import and every
instance writes its final stats."
usage_guard "$@"

KEEP=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --keep-tmux) KEEP=1 ;;
    --force)     FORCE=1 ;;
    *) usage ;;
  esac
done

if [ "$FUZZ_BACKEND" = docker ]; then
  mapfile -t running < <(docker ps -q --filter "name=^${CONTAINER_PREFIX}-" 2>/dev/null)
  if [ "${#running[@]}" -eq 0 ]; then
    log_warn "no ${CONTAINER_PREFIX}-* containers running"
  else
    log "stopping ${#running[@]} instances"
    docker kill --signal=INT "${running[@]}" >/dev/null 2>&1 || true
    for _ in $(seq 30); do
      sleep 1
      [ -z "$(docker ps -q --filter "name=^${CONTAINER_PREFIX}-")" ] && break
    done
    [ "$FORCE" = 1 ] && docker rm -f $(docker ps -aq --filter "name=^${CONTAINER_PREFIX}-") >/dev/null 2>&1 || true
  fi
else
  pids="$(pgrep -f "afl-fuzz .*-o $OUT_DIR" || true)"
  if [ -z "$pids" ]; then
    log_warn "no afl-fuzz instances on $OUT_DIR"
  else
    log "stopping $(wc -w <<<"$pids") instances"
    # shellcheck disable=SC2086
    kill -INT $pids 2>/dev/null || true
    for _ in $(seq 30); do
      sleep 1
      pgrep -f "afl-fuzz .*-o $OUT_DIR" >/dev/null || break
    done
    [ "$FORCE" = 1 ] && pkill -KILL -f "afl-fuzz .*-o $OUT_DIR" 2>/dev/null || true
  fi
fi

if [ "$KEEP" = 0 ] && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION"
  log_ok "tmux session '$TMUX_SESSION' killed"
fi

# In full: the campaign totals are the last thing the report prints now, and a
# head -30 would cut them off on any plan with more than a few lanes.
"$REPO_DIR/fuzz" status 2>/dev/null || true
