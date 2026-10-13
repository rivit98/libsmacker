# The seed corpora, one directory per group.
#
#   ./fuzz seeds                        # what each group holds
#   ./fuzz seeds --import DIR           # add DIR's files to a group's seeds
#   ./fuzz seeds --cmin                 # re-minimize the seeds in place
#   ./fuzz seeds --group path ...       # restrict either of those to one group
#
# Seeds live in fuzzer/seeds/<group>/ and are checked in: they are an input to
# the campaign, not an artifact of it, and rebuilding them from scratch on
# another machine would need the same external corpora to be lying around.
# Nothing writes to them except the two commands above - afl-fuzz only reads -i.
# A group is simply a directory there; --import into a new name creates one.
#
# A seed is a plain .smk file: test_decode() opens the whole input, and takes
# its last byte as the seek target as well. --import copies files as they are;
# by hand it is
#
#   cp clip.smk fuzzer/seeds/smk/clip
#
# Minimization runs under TC when it is set, so a seed is kept only if it adds
# coverage in those test cases; unset, it is kept if it adds coverage anywhere.

USAGE="usage: $PROG seeds [--import DIR] [--cmin] [--group <group>]

  (no options)  list what each group holds
  --import DIR  add DIR's files to a group's seeds - needs --group
  --cmin        re-minimize the checked-in seeds in place
  --group <g>   restrict either action to one group

Seeds live in $SEED_ROOT/<group>/ and are checked in. --import copies the
files as they are - a seed is a plain .smk file - and then runs afl-cmin, so
an import only grows the corpus by what adds coverage; importing into a
group name that does not exist yet creates it. Minimization runs under TC when
it is set, so a seed is kept only if it adds coverage in those test cases."
usage_guard "$@"

MODE=list; IMPORT_DIR=""; ONLY_GROUP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --import) MODE=import; IMPORT_DIR="$2"; shift ;;
    --cmin)   MODE=cmin ;;
    --group)  ONLY_GROUP="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

mapfile -t groups < <(find "$SEED_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
if [ -n "$ONLY_GROUP" ]; then
  [ "$MODE" = import ] || [ -d "$SEED_ROOT/$ONLY_GROUP" ] \
    || die "no group '$ONLY_GROUP' in $SEED_ROOT (${groups[*]})"
  groups=("$ONLY_GROUP")
fi

# afl-cmin over <dir>, in place. @@ matters: without it the input goes through
# AFL's shared-memory path, which the AFLDriver target only honours under
# afl-fuzz - under showmap it runs on an empty buffer and the corpus collapses
# to a single file.
cmin_into() { # cmin_into <group> <dir>
  local group="$1" dir="$2" tmp before
  tmp="$dir.cmin.$$"
  before="$(count_files "$dir")"

  require_backend
  log "$group: afl-cmin over $before seeds, test cases: ${TC:-all (TC unset)}"
  rm -rf "$tmp"
  # TC reaches the backend only when set: afl_run strips an inherited one.
  afl_run -n "$CONTAINER_PREFIX-cmin-$group" $(env_args "${AFL_ENV[@]}" ${TC:+"TC=$TC"}) -- \
    "afl-cmin -T all -i $(cpath "$dir") -o $(cpath "$tmp") -m none -t $TIMEOUT_FAST -- $B_BIN_FAST @@" >/dev/null

  if [ -n "$(ls -A "$tmp" 2>/dev/null)" ]; then
    rm -rf "${dir:?}"; mv "$tmp" "$dir"
    log_ok "$group: $before -> $(count_files "$dir") seeds"
  else
    rm -rf "$tmp"
    log_err "$group: afl-cmin produced nothing, keeping the $before seeds it had"
  fi
}

case "$MODE" in
  list)
    for g in "${groups[@]}"; do
      printf '%-6s %4s seeds  %s\n' "$g" "$(count_files "$SEED_ROOT/$g")" "$SEED_ROOT/$g"
    done ;;

  import)
    [ -d "$IMPORT_DIR" ] || die "no such directory: $IMPORT_DIR"
    [ -n "$ONLY_GROUP" ] || die "--import needs --group (existing: ${groups[*]})"
    g="$ONLY_GROUP"
    dir="$SEED_ROOT/$g"
    ensure_dirs "$dir"

    n=0; added=0
    while IFS= read -r f; do
      base="$(printf '%s' "$(basename "$f")" | tr -c 'A-Za-z0-9_.' _)"
      out="$dir/imported_$(printf '%05d' "$n")_$base"
      cp -- "$f" "$out"
      # An empty file exercises nothing.
      [ "$(stat -c%s "$out")" -ge "$MIN_SEED_BYTES" ] && added=$((added + 1)) || rm -f "$out"
      n=$((n + 1))
    done < <(find "$IMPORT_DIR" -type f -size -64k 2>/dev/null || true)

    [ "$added" -gt 0 ] || die "$g: nothing usable in $IMPORT_DIR"
    log_ok "$g: imported $added seeds from $IMPORT_DIR"
    [ -x "$BIN_FAST" ] && cmin_into "$g" "$dir" \
      || log_warn "no $BIN_FAST - skipping afl-cmin (./fuzz build fast, then ./fuzz seeds --cmin --group $g)" ;;

  cmin)
    [ -x "$BIN_FAST" ] || die "$BIN_FAST missing - run ./fuzz build fast"
    for g in "${groups[@]}"; do
      [ -n "$(ls -A "$SEED_ROOT/$g" 2>/dev/null)" ] || { log_warn "$g: no seeds"; continue; }
      cmin_into "$g" "$SEED_ROOT/$g"
    done ;;
esac
