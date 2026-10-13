# Check that everything the ./fuzz commands run is installed, and print what
# is missing together with the commands it breaks.
#
#   ./fuzz deps                         # the host, then the resolved backend
#   FUZZ_BACKEND=docker ./fuzz deps     # the docker backend instead
#
# The list is the Requirements section of fuzzer/README.md, kept here as data:
# a change to one belongs in the other. The ./fuzz commands themselves still
# check nothing up front - a missing binary reports itself when the command
# that needs it runs - so this is the one place that looks for all of them.
#
# Host tools are looked up here. Backend tools are looked up where the commands
# run them: through afl_run, so on the host backend with $AFL_PATH in front of
# PATH, and on the docker backend inside $FUZZ_IMAGE - with the same
# find_llvm_tool lookup coverage.sh uses, so a versioned llvm-cov-NN counts.
#
# Exit status: 0 when nothing required is missing, 1 otherwise. Optional
# tools (LTO, afl-whatsup, gawk) only ever warn.

USAGE="usage: $PROG deps

Checks every tool the ./fuzz commands need - on the host, then in the backend
(FUZZ_BACKEND, resolved: $FUZZ_BACKEND) - and prints what is missing and which
commands it breaks. Nothing is installed or pulled: on the docker backend the
image has to be there already.

Exit status 1 when a required tool is missing; optional ones only warn."
usage_guard "$@"
[ $# -eq 0 ] || usage

missing=(); optional=()

# row <ok|missing|warn|optional> <name> <detail> <needed by>
# A missing tool is recorded with what it breaks, for the summary; a missing
# optional one only warns.
row() {
  local st="$1" name="$2" detail="$3" by="$4" mark colour
  case "$st" in
    ok)       mark='[+]'; colour="$C_GRN" ;;
    missing)  mark='[-]'; colour="$C_RED"; missing+=("$name ($by)") ;;
    optional) mark='[!]'; colour="$C_YEL"; optional+=("$name ($by)"); detail="not found - optional" ;;
  esac
  printf '  %s%s%s %-16s %-44s %s%s%s\n' "$colour" "$mark" "$C_OFF" "$name" "$detail" "$C_DIM" "$by" "$C_OFF"
}

# found <name> <path or ""> <needed by> [optional]
found() {
  if [ -n "$2" ]; then row ok "$1" "$2" "$3"
  elif [ "${4:-}" = optional ]; then row optional "$1" "" "$3"
  else row missing "$1" "not found" "$3"
  fi
}

# A line of explanation under the row above it.
note() { printf '      %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

host_tool() { # host_tool <name> <needed by> [optional]
  found "$1" "$(command -v "$1" 2>/dev/null || true)" "$2" "${3:-}"
}

# ── host ──────────────────────────────────────────────────────────────────────
log_step "host - what the ./fuzz scripts run themselves"

if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
  row ok bash "$BASH_VERSION" "every command"
else
  row missing bash "$BASH_VERSION - 4.3 or newer needed" "every command"
fi
for t in lscpu find grep sed sort awk; do host_tool "$t" "every command"; done
host_tool tmux "run, stop"
host_tool df "status"
host_tool nice "triage-all"
host_tool ps "triage-all"
# -d and -r are GNU: busybox and BSD xargs lack them, and triage-all needs both.
if ! command -v xargs >/dev/null 2>&1; then
  row missing xargs "not found" "triage-all"
elif xargs --version 2>/dev/null | grep -q GNU; then
  row ok xargs "$(command -v xargs) (GNU)" "triage-all"
else
  row missing xargs "$(command -v xargs) is not GNU xargs" "triage-all"
fi
host_tool ssh "grab"
host_tool rsync "grab"

if [ "$FUZZ_BACKEND" = host ]; then
  for t in taskset pgrep pkill; do host_tool "$t" "FUZZ_BACKEND=host: pinning, status, stop"; done
  # clean containers is the only other user of docker, and only a docker
  # campaign leaves containers behind.
  host_tool docker "clean containers" optional
else
  host_tool docker "FUZZ_BACKEND=docker"
fi

# ── backend ───────────────────────────────────────────────────────────────────
if [ "$FUZZ_BACKEND" = host ]; then
  log_step "backend: host - AFL++ and the toolchain on ${AFL_PATH:+\$AFL_PATH ($AFL_PATH), then }PATH"
else
  log_step "backend: docker - inside $FUZZ_IMAGE"
fi

# One line per tool, "<name>|<path>", printed by a script that runs in the
# backend. "|", not a tab: read collapses a run of tabs, so an empty path would
# swallow the field after it.
#
# The symbolizer is tested, not looked up: a tiny ASAN program is built and
# made to report, and the line is "symbolizer|<yes|no|hang|nocompile>|<the one
# the runtime used>|<newest llvm-symbolizer-NN>|<ulimit -n>". A name on PATH proves little -
# the runtime looks up the bare name, $ASAN_SYMBOLIZER_PATH, and on
# Debian/Ubuntu's clang also a versioned path compiled into it - and what
# triage needs is the frames in its logs symbolized. Under timeout, because
# before it starts the symbolizer the runtime closes every fd below ulimit -n,
# and docker's default limit (2^31) makes that take minutes: measured on
# $FUZZ_IMAGE, 0.07 s with ulimit -n 1024, still spinning after 5 minutes
# without.
read -r -d '' BACKEND_PROBE <<'PROBE' || true
for t in afl-fuzz afl-cc afl-clang-fast afl-clang-lto afl-showmap afl-cmin afl-tmin afl-whatsup \
         cmake make clang llvm-ar llvm-ranlib timeout cov-analysis gawk; do
  printf '%s|%s\n' "$t" "$(command -v "$t" 2>/dev/null || true)"
done
for t in llvm-profdata llvm-cov; do
  p="$(find_llvm_tool "$t" 2>/dev/null || true)"
  printf '%s|%s\n' "$t" "${p:+$(command -v "$p")}"
done
alt="$(compgen -c llvm-symbolizer- 2>/dev/null | sort -uV | tail -n 1)"
d="$(mktemp -d)"
printf 'int main(void){volatile int*p=(int*)__builtin_malloc(4);__builtin_free((void*)p);return p[0];}\n' >"$d/t.c"
if clang -g -fsanitize=address -o "$d/t" "$d/t.c" >/dev/null 2>&1; then
  rc=0; out="$(ASAN_OPTIONS=verbosity=2:detect_leaks=0 timeout 10 "$d/t" 2>&1)" || rc=$?
  used="$(printf '%s\n' "$out" | grep -o 'Using llvm-symbolizer [a-z -]*: .*' | head -n 1 | sed 's/.*: //')"
  if [ "$rc" -eq 124 ]; then ok=hang
  elif printf '%s\n' "$out" | grep -q ' in main .*t\.c:1'; then ok=yes
  else ok=no
  fi
else
  ok=nocompile; used=""
fi
rm -rf "$d"
printf 'symbolizer|%s|%s|%s|%s\n' "$ok" "$used" "$alt" "$(ulimit -n)"
PROBE

probe_ok=1
if [ "$FUZZ_BACKEND" = docker ]; then
  if ! command -v docker >/dev/null 2>&1; then
    probe_ok=0
  elif ! docker info >/dev/null 2>&1; then
    row missing "docker daemon" "not reachable - running? user in the docker group?" "FUZZ_BACKEND=docker"
    probe_ok=0
  elif ! docker image inspect "$FUZZ_IMAGE" >/dev/null 2>&1; then
    row missing "image" "$FUZZ_IMAGE not pulled - docker pull $FUZZ_IMAGE" "FUZZ_BACKEND=docker"
    probe_ok=0
  else
    row ok "image" "$FUZZ_IMAGE" "FUZZ_BACKEND=docker"
  fi
  [ "$probe_ok" = 1 ] || log_warn "the backend's tools cannot be checked until docker and the image are there"
fi

if [ "$probe_ok" = 1 ]; then
  declare -A at=()
  sym_ok=""; sym_used=""; sym_alt=""; sym_nofile=""
  while IFS='|' read -r name path used alt nofile; do
    if [ "$name" = symbolizer ]; then sym_ok="$path"; sym_used="$used"; sym_alt="$alt"; sym_nofile="$nofile"
    else at[$name]="$path"
    fi
  done < <(afl_run -- "$LLVM_TOOL_FN"$'\n'"$BACKEND_PROBE")

  b() { found "$1" "${at[$1]:-}" "$2" "${3:-}"; }
  b afl-fuzz       "run"
  b afl-cc         "build"
  b afl-clang-fast "build"
  b afl-clang-lto  "build: LTO mode" optional
  b afl-showmap    "seeds, cmin, coverage --edges"
  b afl-cmin       "seeds, cmin, coverage --edges"
  b afl-tmin       "cmin --tmin"
  b afl-whatsup    "status: summary at the bottom" optional
  b cmake          "build"
  b make           "build"
  b clang          "build"
  b llvm-ar        "build: LTO mode" optional
  b llvm-ranlib    "build: LTO mode" optional
  b timeout        "triage"
  b cov-analysis   "coverage"
  b llvm-profdata  "coverage"
  b llvm-cov       "coverage"
  b gawk           "coverage --stability" optional

  # Without a symbolizer every triage log has raw addresses instead of
  # frames, which is worth a line of its own.
  by="triage: symbolized frames"
  case "$sym_ok" in
    yes) row ok llvm-symbolizer "${sym_used:-symbolizes}" "$by" ;;
    hang)
      row missing llvm-symbolizer "starting it hangs: ulimit -n is $sym_nofile" "$by"
      note "the runtime closes every fd below ulimit -n before it starts the symbolizer;"
      note "a report then spins until triage's --timeout. Lower it (docker: --ulimit nofile=65536)." ;;
    no)
      if [ "$FUZZ_BACKEND" = host ] && [ -n "${ASAN_SYMBOLIZER_PATH:-}" ]; then
        row missing llvm-symbolizer "ASAN_SYMBOLIZER_PATH does not symbolize" "$by"
        note "ASAN_SYMBOLIZER_PATH=$ASAN_SYMBOLIZER_PATH"
      elif [ -n "$sym_alt" ]; then
        row missing llvm-symbolizer "not found - only $sym_alt" "$by"
        note "symlink $sym_alt as llvm-symbolizer on PATH, or set ASAN_SYMBOLIZER_PATH to it"
      else
        row missing llvm-symbolizer "not found - raw addresses in every log" "$by"
      fi ;;
    *) row missing llvm-symbolizer "untested: clang -fsanitize=address fails" "$by" ;;
  esac
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
if [ "${#optional[@]}" -gt 0 ]; then
  log_warn "${#optional[@]} optional tool(s) missing - everything works without them:"
  for m in "${optional[@]}"; do printf '      %s\n' "$m" >&2; done
fi
if [ "${#missing[@]}" -gt 0 ]; then
  log_err "${#missing[@]} missing:"
  for m in "${missing[@]}"; do printf '      %s\n' "$m" >&2; done
  exit 1
fi
log_ok "everything required is installed"
