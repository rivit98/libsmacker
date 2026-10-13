# Minimize the campaign's combined queue into $CMIN_DIR, for use as the seed
# corpus of the next run.
#
#   ./fuzz cmin            # afl-cmin over every instance queue
#   ./fuzz cmin --tmin     # also afl-tmin each survivor (slow, rarely worth it)
#
# Only the *queue* is minimized.  Crash inputs are never minimized here: the
# repo's bug reports keep the original artifact bytes, because a minimizer only
# preserves "some crash" and can silently drift onto a different bug.

USAGE="usage: $PROG cmin [--tmin]

  (no options)  afl-cmin over every instance queue into \$CMIN_DIR
  --tmin        also afl-tmin each survivor (slow, rarely worth it)

Only the queue is minimized - the seed corpus of the next campaign. Crash
inputs are never minimized: a minimizer only preserves 'some crash' and can
silently drift onto a different bug, and the reports keep the original bytes."
usage_guard "$@"

case "${1:-}" in ""|--tmin) ;; *) usage ;; esac

require_backend
need_bin fast >/dev/null

TMIN=0
[ "${1:-}" = "--tmin" ] && TMIN=1

ALL="$CAMPAIGN_DIR/queue.all"
rm -rf "$ALL" "$CMIN_DIR"; ensure_dirs "$ALL"

n=0
for q in "$OUT_DIR"/*/queue; do
  [ -d "$q" ] || continue
  inst="$(basename "$(dirname "$q")")"
  for f in "$q"/id:*; do
    [ -f "$f" ] || continue
    cp -- "$f" "$ALL/${inst}_$(basename "$f" | tr -c 'A-Za-z0-9_.' _)"
    n=$((n + 1))
  done
done
log "$n queue entries collected"

# afl-cmin/afl-showmap must be given the input as a FILE argument (@@).
# Without it they hand the input to the target through AFL's shared-memory
# path, which the AFLDriver target only honours under afl-fuzz - under
# showmap it runs on an empty buffer, every map comes back with ~20 edges
# instead of ~3200, and the corpus "minimizes" down to one file.
# TC, when set, keeps the minimization on the test cases the campaign fuzzed.
afl_run -n "$CONTAINER_PREFIX-cmin" $(env_args "${AFL_ENV[@]}" ${TC:+"TC=$TC"}) -- \
  "afl-cmin -T all -i $(cpath "$ALL") -o $B_CMIN_DIR -m none -t $TIMEOUT_FAST -- $B_BIN_FAST @@"

if [ "$TMIN" = 1 ]; then
  log "afl-tmin pass"
  afl_run -n "$CONTAINER_PREFIX-tmin" $(env_args "${AFL_ENV[@]}") -- \
    "for f in $B_CMIN_DIR/*; do afl-tmin -i \$f -o \$f.tmin -m none -t $TIMEOUT_FAST -- $B_BIN_FAST @@ >/dev/null 2>&1 && mv \$f.tmin \$f; done"
fi

log_ok "$(count_files "$CMIN_DIR") files in $CMIN_DIR"
log "next campaign: SEED_DIR=$CMIN_DIR ./fuzz run   (or ./fuzz seeds --force)"
rm -rf "$ALL"
