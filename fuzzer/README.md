# AFL++ campaign for libsmacker

One entry point, `./fuzz` at the repository root, drives everything: builds, seeds, the campaign, triage
and coverage. AFL++ is the only fuzzing engine in the repo — libFuzzer is gone,
and the two engine-free binaries (`fuzz2`, `fuzz_cov`) get their `main()` from
the harness itself.

```bash
./fuzz build                        # every variant; ./fuzz build fast for one
./fuzz run                          # start the campaign and attach
```

## Requirements

`./fuzz deps` checks all of them - on the host and inside the backend - and
names what is missing and which commands it breaks. The other commands check
nothing up front: a missing binary reports itself when the command that needs
it runs.

**On the host, whatever the backend** — what the `./fuzz` scripts run themselves:

| binary | needed by |
|---|---|
| `bash` 4.3+ | every command (`mapfile`) |
| `tmux` | `run`, `stop` |
| `lscpu` | every command: one instance per physical core |
| `awk`, `df` | `status` |
| `nice`, `ps`, GNU `xargs` | `triage-all`: replays run nice'd through `xargs -P`, and an interrupted sweep ends their process tree |
| `docker` | `FUZZ_BACKEND=docker`, `clean containers` — the daemon reachable without sudo |
| `taskset`, `pgrep`, `pkill` | `FUZZ_BACKEND=host`: core pinning, `status`, `stop` |
| `ssh`, `rsync` | `grab` — `root@IP` reachable without a password prompt; the remote hosts need `find`, `grep -P`, `xargs` and `rsync` |

**In the backend** — on `PATH` (or `$AFL_PATH`) for `host`, inside
`aflplusplus/aflplusplus:stable` for `docker`:

| binary | needed by | notes |
|---|---|---|
| `afl-fuzz` | `run` | |
| `afl-cc`, `afl-clang-fast` | `build` | plus `afl-clang-lto` when `afl-cc -h` reports LTO available |
| `afl-showmap`, `afl-cmin` | `seeds`, `cmin`, `coverage --edges` | |
| `afl-tmin` | `cmin --tmin` | |
| `afl-whatsup` | `status` | optional summary at the bottom |
| `cmake`, `make` | `build` | |
| `clang` | `build` | `cov`, `repro` and `repro-msan` are plain clang |
| `llvm-ar`, `llvm-ranlib` | `build`, LTO mode | optional; only the bare names are looked up |
| `timeout` | `triage` | |
| `cov-analysis` | `coverage` | in the docker image; usually not on a host |
| `llvm-profdata`, `llvm-cov` | `coverage` | must match `clang`'s major version; `-NN` names are found |
| `gawk` | `coverage --stability` | not in the docker image |
| `llvm-symbolizer` | `triage`: symbolized frames | the runtime finds the bare name, `ASAN_SYMBOLIZER_PATH`, or — Ubuntu's clang, the docker image's included — its own `/usr/bin/llvm-symbolizer-NN`. It closes every fd below `ulimit -n` before starting it, and docker's default limit (2^31) makes that take minutes. `./fuzz deps` builds a small ASAN program and checks its report is symbolized |

## Commands

`./fuzz help` lists the commands; **`./fuzz <command> -h` prints that command's
options** — they are documented in the command itself, not here, so the two
cannot drift apart. `-h` answers before any backend is resolved or any image
pulled. Everything that varies between campaigns is an environment variable
(see [Environment](#environment)).

| | |
|---|---|
| `deps` | check the tools below are installed — see [Requirements](#requirements) |
| `build` | build the harness variants — see [The builds](#the-builds) |
| `seeds` | the seed corpora — see [Seed groups](#seed-groups) |
| `run` | start the campaign in tmux — see [The instance mix](#the-instance-mix) |
| `status` | dashboard and health checks — see [Health checks](#health-checks-window-0) |
| `stop` | end the campaign |
| `triage` | replay one artifact through the sanitizer builds, one log per build in `logs/` - `logs_<TC>/` with `TC` set |
| `triage-all` | replay every crash and hang of a campaign through `triage`, `-j` artifact × variant replays at a time, with a live status line (replays done and the rate, nothing else); every replay keeps its log, in the same `logs/` or `logs_<TC>/` |
| `grab` | move the crashes and hangs of remote campaigns into one directory: `-o DIR IP...` |
| `cmin` | minimize the campaign queue for the next run |
| `coverage` | coverage report, or `--edges` for the AFL-only metric |
| `clean` | remove builds, logs, state, crashes or containers - only the targets named, of the current campaign (or `--all`: every target of every campaign) |

## Logs and stats

Each instance tab shows AFL's own status screen, repainted in place
(`AFL_FORCE_UI=1` — without it the pipe into the log would put afl-fuzz in its
non-tty mode, one scrolling line per fuzzed queue entry). `$LOG_DIR/<instance>.log`
gets only the message lines — startup, warnings, aborts, the closing summary —
so it stays a few dozen KB instead of half a megabyte a minute. Per-second
numbers live in `$OUT_DIR/<instance>/{fuzzer_stats,plot_data}`, which is what
`./fuzz status` reads.

## Environment

| | |
|---|---|
| `FUZZ_BACKEND` | `auto` (default), `docker`, `host` |
| `FUZZ_GROUP` | seeds to start from, `fuzzer/seeds/<group>` (`smk`), and the campaign's name. Unset: one empty seed, campaign `all` |
| `TC` | restrict every instance to one group function (`test_smk`) or one test case (`test_decode`). Unset: every test case |
| `JOBS` | instances (default: one per physical core) |
| `FUZZ_PLAN` | `auto` (default: the smallest plan with at least `JOBS` lanes), `8`, `16`, `32`, or a path |
| `FUZZ_DIR` | campaign state root (default `../fuzz/libsmacker`) |
| `SEED_ROOT` | seed corpora root (default `fuzzer/seeds`) |
| `FUZZ_CC_MODE` | `lto` or `fast`, forcing afl-cc's instrumentation mode |
| `FUZZ_MAX_LEN` | `-G`, max input length (default 10000) |
| `REFRESH` | dashboard refresh seconds (default 600) |

Every knob this project invents is `FUZZ_*`, never `AFL_*`: afl-cc warns about
`AFL_*` names it does not know, and that warning should stay meaningful.

## Backends

| `FUZZ_BACKEND` | what runs AFL | paths |
|---|---|---|
| `host` | a system install, or `$AFL_PATH` | the host's own; pinning via `taskset` |
| `docker` | `aflplusplus/aflplusplus:stable` | `$REPO_DIR -> /repo`, `$FUZZ_DIR -> /fuzz`; pinning via `--cpuset-cpus` |
| `auto` | host if `afl-fuzz` is there, else docker | |

Nothing has to be installed or pulled by hand: the image is pulled the first
time a command needs it. Binaries are produced by the same backend that runs
them, so clang, the instrumentation pass and libc never disagree — switching
backends means `./fuzz build --clean`.

## Layout

```
fuzz               the entry point, at the repository root: ./fuzz <command> [options]
fuzzer/
├── seeds/         the seed corpora, one directory per group (checked in)
├── plans/         instance plans: 8.plan, 16.plan, 32.plan
└── lib/
    ├── common.sh       configuration, logging, backend plumbing (sourced first)
    ├── deps.sh         check the Requirements are installed
    ├── build.sh        the build variants
    ├── seeds.sh        seed corpora: list, import, minimize
    ├── run.sh          the tmux campaign (window 0 = health, 1..N = instances)
    ├── status.sh       dashboard + health checks
    ├── stop.sh         SIGINT every instance, drop the session
    ├── triage.sh       replay one artifact through the sanitizer builds
    ├── triage-all.sh   sweep a campaign's crashes and hangs through ./fuzz triage
    ├── grab.sh         move remote crashes and hangs here (ssh + rsync)
    ├── cmin.sh         minimize the queue for the next campaign
    ├── clean.sh        remove builds/logs/state/crashes/containers
    └── coverage.sh     cov-analysis report / edges / stability / search
```

Command files are sourced by `fuzz`, not exec'd, so they share one configuration
and one logger. Campaign *state* lives outside the repo, so a `git clean` never
eats a running campaign: `../fuzz/libsmacker/{state/<group or all>,logs,logs_<TC>,cov}`.

## The builds

| build | flags | used for |
|---|---|---|
| `fast` | plain afl-cc | every throughput lane; catches SEGV/abort |
| `asan` | `AFL_USE_ASAN=1 AFL_USE_UBSAN=1` | the lane that classifies memory bugs. `AFL_USE_UBSAN` implies `-fno-sanitize-recover=undefined`, so a UBSAN report becomes a saved crash |
| `cmplog` | `AFL_LLVM_CMPLOG=1` | passed to `afl-fuzz -c`, never fuzzed directly |
| `msan` | `AFL_USE_MSAN=1` | uninitialized reads, for triage — the plans get MSAN from `sand-msan` |
| `lsan` | `AFL_USE_LSAN=1` | per-input leaks via `__AFL_LEAK_CHECK()` |
| `laf` | `AFL_LLVM_LAF_ALL=1` | laf-intel lanes: multi-byte compares split into byte compares, so a partial keyword match registers as coverage |
| `sand-asan` | `AFL_USE_ASAN=1 AFL_USE_UBSAN=1 AFL_LLVM_ONLY_FSRV=1` | SAND oracle for `afl-fuzz -w`: sanitizers and a fork server, no edge map (`afl-showmap`: 0 tuples) |
| `sand-msan` | `AFL_USE_MSAN=1 AFL_LLVM_ONLY_FSRV=1` | SAND MSAN oracle; `afl-clang-fast`, like `msan` |
| `cov` | `-fprofile-instr-generate`, plain clang | `fuzz_cov` for `./fuzz coverage` |
| `repro` | `-O0`, asan+ubsan, plain clang, `-DENABLE_ASAN=ON` | `fuzz2`: the `RR()`/`RF()` reproducer |
| `repro-msan` | `-O0`, msan, plain clang, `-DFUZZ_REPRO_SANITIZER=memory`, `-fsanitize=memory` in `CMAKE_C_FLAGS` | the same `fuzz2` for MSAN-only findings, which `repro` replays silently |

**Which compiler each build uses**, and why it is not uniform:

* every `fuzz` variant is built by **afl-cc** — `afl-clang-lto` when afl-cc
  reports LTO available (collision-free edge IDs), else `afl-clang-fast`.
  `afl-clang-lto -v` prints "clang version …" because it *is* a clang wrapper;
  verify instrumentation with `nm build/<variant>/fuzz | grep -c __afl_` (≈130)
  or `afl-showmap … -- build/<variant>/fuzz <input>` (≈240 tuples on a seed here).
* **`cov`, `repro` and `repro-msan` are deliberately plain clang** —
  instrumenting the coverage binary would measure AFL's counters instead of the
  library, and the reproducers have no use for edge counters.
* **`repro-msan` instruments through `CMAKE_C_FLAGS`**, not just `fuzz2`: MSAN
  reports uninitialized reads out of *every* uninstrumented translation unit it
  links, so the library has to be built with it too. `FUZZ_REPRO_SANITIZER`
  (`src/fuzz/CMakeLists.txt`) only picks what `fuzz2` itself gets, since ASAN
  and MSAN cannot share one binary.
* **`msan` is pinned to `afl-clang-fast`**: in LTO mode the binary links but its
  fork server dies with SIGSEGV on the first exec.
* **`repro` needs `-DENABLE_ASAN=ON`** so the *library* is instrumented too;
  an uninstrumented `smacker.c` reports nothing for an overflow inside it.
* **The top-level `CMakeLists.txt` is fuzzing-only.** The library itself is
  built with autotools; CMake exists so every variant configures the same way
  (`smacker_static` plus `src/fuzz/CMakeLists.txt`).

## Seed groups

The harness groups its test cases by the shape of input they consume; each
group is a function at the bottom of `main.c`, and seeds are kept per group in
`fuzzer/seeds/<group>/`. Which seeds a campaign starts from (`FUZZ_GROUP`) and
which test cases it runs (`TC`) are two separate settings — neither implies
the other, and both are unset by default:

| group | group function (`TC=`) | feeds | input |
|---|---|---|---|
| `smk` | `test_smk` | `test_decode`: `smk_open_memory()`, decode every frame, then `smk_seek_keyframe()` and decode the keyframe and the frame after it | a `.smk` file |

| | starts from | runs | state, tmux session |
|---|---|---|---|
| `./fuzz run` | one empty seed | every test case | `state/all`, `afl-libsmacker-all` |
| `FUZZ_GROUP=smk ./fuzz run` | `fuzzer/seeds/smk` | every test case | `state/smk`, `afl-libsmacker-smk` |
| `FUZZ_GROUP=smk TC=test_decode ./fuzz run` | `fuzzer/seeds/smk` | `test_decode` only | `state/smk`, `afl-libsmacker-smk` |

The empty seed is the `SMK2` signature alone, generated
into `../fuzz/libsmacker/seed.empty/`. The checked-in seeds are better: small
hand-built files (8x8 video with real Huffman trees, palette records, raw and
DPCM audio, an SMK4 file with a ring frame, an audio-only file) that cover
about a third of the edge map before any fuzzing.

`TC=` also accepts an individual test case name, which runs that one inside its
group. `TC` reaches the instances explicitly — the backends deliberately do not
inherit it, because a stray `TC` in a shell silently restricts a whole campaign.

Seeds are **checked in** under `fuzzer/seeds/<group>/`: they are an input to a
campaign, not an artifact of it. Adding material:

```bash
./fuzz seeds --import ~/smk-samples --group smk   # add, minimize
./fuzz seeds --cmin --group smk                   # re-minimize in place
```

`--import` copies the files as they are - a seed is a plain `.smk` file - and
then runs `afl-cmin` — under `TC` when you set it, otherwise against every test
case — so an import only grows the corpus by what adds coverage. Importing into
a group name that does not exist yet creates it. By hand, one seed is just:

```bash
cp clip.smk fuzzer/seeds/smk/clip
```

Real Smacker files are mostly far larger than `FUZZ_MAX_LEN`; afl-fuzz skips
seeds over `-G`, so trim them (fewer frames) before importing.

### Input layout

The whole input is the `.smk` file, handed to `smk_open_memory()`. Its last
byte also picks the seek target - `smk_seek_keyframe()` goes to it modulo the
frame count - without being taken out of the file.

There is no other configuration: every track is enabled, every frame decoded.
There is no allocation failure injection either: no reachable allocation has a
failure path that a malformed file does not already reach.

`test_decode` decodes every frame, within a budget of 4M bytes of decoded
output per test case - video pixels plus audio bytes (`DECODE_BUDGET` in
`main.c`). Past it every track is disabled and the remaining frames are only
walked: both decoders produce output without consuming input, so ~1100 tiny
frames in 10 KB once decoded 640x480 in 620 ms and 4096x4096 in 27 s. Video
also stays off for a frame over 4096 px on a side (`VIDEO_DIM_MAX`) or over
the whole budget on its own: the decoder walks every block row of the
header's height, and `h = 0xff000000` is a billion iterations.

The budget is checked between frames, so the first frame is capped separately:
`w*h` plus the `audio_size` header field (offset `0x18`, 4 bytes per track)
of every enabled audio track must fit in it. Tracks are kept in order while
they fit; the rest stay disabled. `audio_size` sizes the track's buffer, and
an empty huff8 tree fills it without consuming input - one 300-byte file
declared 3.9 GB. This bounds decoding only as far as the library honours its
own buffer size: issue #7 (`report3.md`) writes past it, up to the unpacked
size the chunk declares, so those inputs stay slow until it is fixed.

There is no allocation size cap: header fields size the buffers directly (up
to 4 GB for an audio buffer, 32 GB for the chunk-size table), and those
allocations really happen. They are cheap all the same - measured, a 32 GB
`calloc()` succeeds in the fast, asan and msan builds with a peak RSS of a few
MB, since nothing touches the pages before the short input runs out and the
open fails. A size beyond the sanitizer's own limit becomes `NULL` under
`allocator_may_return_null=1`, and `smk_malloc()` exits cleanly.

## The instance mix

One instance per **physical** core (SMT siblings roughly halve each other's
speed), each pinned with `--cpuset-cpus` (docker) or `taskset` (host), all
sharing one `-o` directory. Tab 0 is the `status --loop` dashboard, tabs 1..N
the lanes of a plan:

```bash
./fuzz run                      # FUZZ_PLAN=auto: 8.plan on 8 cores, 32.plan on 32
JOBS=12 ./fuzz run              # the first 12 lanes of 16.plan
FUZZ_GROUP=smk TC=test_smk FUZZ_PLAN=32 ./fuzz run
```

Plans live in `plans/<lanes>.plan`, one lane per line
(`name | variant | afl-fuzz args | env`; the tokens are documented at the top
of `lib/run.sh`). `auto` takes the smallest plan with at least `JOBS` lanes and
runs its first `JOBS`, so each file is ordered by what to keep when cores are
short. A lane whose build is missing is skipped, and a missing SAND oracle is
dropped from its lane, each with a warning.

Every plan follows AFL++'s `docs/fuzzing_in_depth.md`, "Using multiple cores":

| | 8 | 16 | 32 |
|---|---|---|---|
| `-M main`: dictionary, deterministic stage, `AFL_FINAL_SYNC=1` | 1 | 1 | 1 |
| full ASAN+UBSAN lanes | 1 | 2 | 4 |
| `lsan` | – | 1 | 1 |
| CMPLOG, at least one `-l 2AT` | 1 | 2 | 3 |
| laf-intel | 1 | 1 | 3 |
| other secondaries | 4 | 9 | 20 |

Across the other secondaries (the 32-lane numbers; smaller plans round):
`-Z` 10 %, `AFL_DISABLE_TRIM` 60 %, `-P explore` 40 %, `-P exploit` 20 %, 30 %
without `-a` and the rest `-a binary`, every
power schedule `-p` offers, and MOpt (`-L`) on two. A few lanes run without
the dictionary; they still get the LTO autodictionary. Each plan's header
carries its own count.

* **Every secondary runs `-z`.** Since AFL++ 4.20 the deterministic stage is
  on in every instance by default, and it produces the same inputs wherever it
  runs — only `main` keeps it.
* **Sanitizers mostly come from SAND oracles** (`docs/SAND.md`). Nearly every
  native, laf and CMPLOG lane carries `-w sand-asan`, a third of them also
  `-w sand-msan`: afl-fuzz re-runs selected inputs through those builds, so a
  lane keeps native speed and still reports ASAN/UBSAN/MSAN findings (saved as
  `+san` crashes). Which inputs get re-run is the whole cost, measured here
  (measured on libfyaml's harness, 5 min, one core each):

  | lane | execs/s | execs through the oracles | edges |
  |---|---|---|---|
  | native, no oracle | 1090 | – | 12464 |
  | `-w sand-asan -w sand-msan`, default abstraction | 380 | 55 % | 11410 |
  | `-w sand-asan -w sand-msan`, `coverage_increase` | 1400 | 1.3 % | 12671 |

  The default re-runs anything with a new simplified coverage map, and this
  libfyaml harness's flag seed and allocator recipes made nearly every input look new.
  `AFL_SAN_ABSTRACTION=coverage_increase` (set for every lane in
  `lib/common.sh`) checks only new queue entries. SAND's authors measure that
  mode missing ~15 % of bugs, which is what the full `asan` lanes cover: they
  check every exec, at about a fifth of native speed.
* **No dedicated `msan` lane** any more: `sand-msan` covers it at native speed.
  `lsan` keeps its lane because SAND has no leak oracle.
* **32 is the ceiling.** AFL++ stops scaling somewhere between 32 and 64
  instances per machine, so `run` caps `JOBS` at the largest plan. With that
  many lanes `AFL_IMPORT_FIRST=1` makes the first minutes slow while every
  lane imports the others' seeds.

## Plan parameters

Everything a plan line can set, and what `run` adds to every lane. The plan
files say *which* lane uses what and why; this is what each knob does.
Sources: `afl-fuzz -h`, `docs/env_variables.md`, `docs/FAQ.md`,
`docs/fuzzing_in_depth.md`, `docs/SAND.md` of the AFL++ install.

### Added by `run`, not written in plans

| | |
|---|---|
| `-M main` | the lane named `main`: the primary. The only lane running the deterministic stage; `-M` also sets `-Z` and disables trimming |
| `-S <name>` | every other lane: a secondary, syncing through the shared `-o` directory |
| `-z` | every secondary: skip the deterministic stage. Since AFL++ 4.20 it is on by default, and it generates the same inputs in every instance that runs it |
| `-i`, `-o` | `fuzzer/seeds/<group>` or the generated empty seed, `../fuzz/libsmacker/state/<group or all>` |
| `-G 10000` | max input length (`FUZZ_MAX_LEN`) |
| `-m none` | no memory limit — required for the sanitizer builds |
| `-t 200` | per-exec timeout in ms, unless the line sets one (`TIMEOUT_FAST`) |

### Plan tokens and flags

| | |
|---|---|
| `-x DICT` | the dictionary, `src/fuzz/smk.dict`. Lanes without it still get the tokens afl-clang-lto extracts from the binary's string compares (the autodictionary) |
| `-a FMT` | input format hint: always `binary` here. Fixes which mutation set havoc uses; without `-a` afl-fuzz decides per queue entry whether it looks like text (the `ascii=` field in its log). The docs: when `-a` is used, 30 % of the lanes should run without it |
| `-c CMPLOG` | CmpLog / RedQueen: the `cmplog` build logs the operands of every comparison and afl-fuzz writes them back into the input where they came from — how magic values and keywords get solved without guessing |
| `-l 2` / `2AT` | CmpLog settings. Digit: which queue entries reach the input-to-state stage. `afl-fuzz -h` calls them file-size classes, but `src/afl-fuzz-one.c` gates on the entry: `2` (default) takes the favored ones, those some edge is top-rated for, and one in every `queued_items` execs; `3` takes **every** entry, and additionally forces `AFL_DISABLE_TRIM` on. `A`: arithmetic solving (the input was offset or scaled before the compare). `T`: transformational solving (the input was transformed before the compare). No plan uses `3` — see 32.plan's header for the measurement |
| `-L` | MOpt: pick mutation operators adaptively (particle-swarm), by which ones found coverage |
| `-p <schedule>` | power schedule — how much mutation energy an entry gets. `explore` (default) and `fast` are the most effective per the FAQ; the rest diversify parallel lanes. `fast`: grows with how often the entry was picked, shrinks with how common its path is. `coe`: like `fast`, but nothing for entries on above-average-frequency paths. `lin` / `quad`: `fast` with linear / quadratic growth. `exploit`: original AFL. `rare`: favours entries hitting rarely-seen edges. `seek`: `explore` ignoring runtime. `mmopt`: `explore` with extra energy for the newest entries |
| `-P explore` / `-P exploit` | fixed mutation strategy: `explore` aims at new coverage, `exploit` at crashes in what is already covered. Without `-P` afl-fuzz switches to exploit after 1000 s without finds and back on new coverage |
| `-Z` | walk the queue in order instead of weighted-random selection (AFL's old queue cycling) |
| `-w ASAN_ORACLE` / `-w MSAN_ORACLE` | SAND oracle: the `sand-asan` / `sand-msan` build, re-run on the inputs `AFL_SAN_ABSTRACTION` selects. A sanitizer report is saved as a crash with `+san` in its name |
| `-t TIMEOUT_SAN` | 1000 ms, for the full sanitizer lanes (`TIMEOUT_MSAN`: 2000 ms). A normal exec takes ~15 µs; see `lib/common.sh` |

### Per-lane environment (plan `env` column)

| | |
|---|---|
| `AFL_FINAL_SYNC=1` | `main` only: one last import from every lane on exit, so `./fuzz cmin` needs only main's queue |
| `AFL_DISABLE_TRIM=1` | do not trim new queue entries. On one instance "usually a bad idea" (env_variables.md); across parallel lanes the docs recommend it on 50–70 % — trimming costs execs, and the other lanes still trim |
| `AFL_CMPLOG_ONLY_NEW=1` | CMPLOG lanes: run CmpLog only on entries found in this run, not on the seeds or a resumed queue. It exempts the startup corpus alone (`afl-fuzz-init.c` marks those entries colorized); entries synced from the other lanes are not exempt, and in a 31-lane campaign those are most of a queue |

### Every lane (`AFL_ENV` and `SAN_ENV` in `lib/common.sh`)

| | |
|---|---|
| `AFL_SAN_ABSTRACTION=coverage_increase` | SAND oracles re-run only new queue entries (see [The instance mix](#the-instance-mix) for the measurement) |
| `AFL_TMPDIR=/dev/shm` | temporary input files on tmpfs, off the disk |
| `AFL_FAST_CAL=1` | 3 calibration runs per entry instead of 8 (more if it turns out unstable). Halved startup on libfyaml's seeds, and speeds up calibrating every new find and synced entry |
| `AFL_TESTCACHE_SIZE=250` | MB of queue entries cached in RAM per lane |
| `AFL_AUTORESUME=1` | re-running `./fuzz run` resumes the existing state instead of refusing |
| `AFL_IMPORT_FIRST=1` | import the other lanes' queues before fuzzing own entries |
| `AFL_IGNORE_SEED_PROBLEMS=1` | skip seeds that crash or time out instead of aborting |
| `AFL_NO_AFFINITY=1` | afl-fuzz does not pin itself — `run` already pins with `taskset` / `--cpuset-cpus` |
| `AFL_SKIP_CPUFREQ=1` | no abort on the `powersave` governor (`afl-system-config` fixes the governor) |
| `AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1` | tolerate a `core_pattern` pipe; the sanitizers abort on error anyway |
| `AFL_FORCE_UI=1` | keep the status screen although stdout is piped into the log filter |
| `TC=<test case>` | only when set for `run`: restricts every lane's harness |
| `ASAN_OPTIONS` … `MSAN_OPTIONS` | fuzzing mode: abort on the first report, no symbolization, AFL owns the signals. The `lsan` lane overrides `LSAN_OPTIONS` to `detect_leaks=1`; `./fuzz triage` switches all of them to reporting mode |

## Health checks (window 0)

The table carries AFL's own `bitmap_cvg` per instance, so a lane stuck well
below the others shows up immediately, next to `PREV-COV`, the same number as
of the previous `status` run — one refresh earlier under `--loop`, so ten
minutes by default — which is where the progress is visible. Each run leaves
its coverage in `state/<group or all>/.status_prev` for the next one, and
`clean state` removes it with the rest of the state. It is a share of *that
binary's* edge map, so it is not comparable across variants: the `asan` build instruments
ASAN's own check branches too and has about twice the edges of `fast`
(measured here: 2385 vs 793), which makes its percentage structurally lower
for the same corpus.

Campaign totals — instances alive, execs, speed, coverage, corpus, crashes,
hangs, cycles without finds — are **not** computed here: the report ends with
`afl-whatsup -d -s`, which already produces all of them. `lib/status.sh` only
adds what `-s` does not have: the per-instance table and the health checks.

`-d` (count dead fuzzers) matters: `afl-whatsup` tests liveness with `kill -0`
on `fuzzer_pid`, and under the docker backend each lane is a separate
container, so it can see none of those PIDs and would otherwise skip every
instance and total up zeros. Whether a lane is really alive is answered by the
health checks below, not by that test.

It reads `state/<group or all>/*/fuzzer_stats` directly (so it still
works when an instance is wedged) and flags:

* an instance whose stats have not moved for 2 min → **dead/wedged**
* stability < 85 % → non-deterministic paths, crashes may not replay
* no new path in an hour → plateau; time for new seeds or `./fuzz cmin`
* live stats with no running instance → a tmux tab died
* `/dev/shm` and state-filesystem free space, load average vs `JOBS`

The `afl-whatsup -d -s` summary follows, printed verbatim.

## Coverage: what AFL can and cannot tell you

AFL's instrumentation is an **edge bitmap** — collision-free edge IDs under LTO,
hit counts, nothing else. It answers "how much of the map has this corpus
covered" and never "which source line was missed". That is why a
clang-instrumented build still exists: source-level coverage needs
`-fprofile-instr-generate`, and AFL++'s own `cov-analysis` shells out to
`llvm-profdata`/`llvm-cov` exactly like everyone else.

| | needs | gives |
|---|---|---|
| `./fuzz coverage --edges` | nothing beyond the `fast` build | `afl-showmap -C`: "4922 of 50176 edges (9.81%)" — a corpus-health trend |
| `./fuzz coverage` | the `cov` build | `cov-analysis report`: summary.txt, **gaps.txt** (uncovered regions ranked by size), HTML, JSON, profdata, plus `lcov.info` |
| `./fuzz coverage --search FILE:LINE` | the `cov` build | which corpus entries reach that line |
| `./fuzz coverage --stability` | the `cov` build **and gawk** | per-line non-deterministic hit counts |

The dashboard's `bitmap_cvg` is the same edge metric, live, for free.

`llvm-profdata` and `llvm-cov` have to match the `clang` that built `fuzz_cov`.
Both `cov-analysis` and the `lcov.info` export resolve them the same way —
`<tool>-<clang major>`, then the bare name, then any version
(`LLVM_TOOL_FN` in `lib/common.sh`).

## Notes / gotchas

* **Seed shape.** A seed is a plain `.smk` file; the harness opens all of it
  and reads its last byte as the seek target too.
* **`-G 10000`.** Room for dozens of frames with real Huffman trees; the
  seeds are a few hundred bytes.
* **`core_pattern`.** The host pipes cores to systemd-coredump, which AFL
  refuses by default; `AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1` is set because
  the sanitizers' `abort_on_error` reports crashes anyway. `sudo
  afl-system-config` (or `docker run --rm --privileged -u 0:0 $FUZZ_IMAGE
  afl-system-config`) fixes it, and is worth up to ~15 % more execs/sec.
* **`TC` is stripped from inherited environments.** The host backend would
  otherwise pass a stray `TC=` from your shell into every exec — measured once
  at 159 edges instead of 3199, a campaign fuzzing a fifth of the target.
  `run` forwards `TC` explicitly when you set it.
* **Persistent mode is automatic**: `libAFLDriver.a` carries `__AFL_LOOP` and
  the deferred forkserver, so the `fast` build runs ~30k execs/sec on a no-op
  input. `AFL_FUZZER_LOOPCOUNT` overrides the loop count.
* **MSAN reports that leave libsmacker are false positives** — glibc is
  uninstrumented.
* **libsmacker is chatty on stderr** (several lines per rejected input, and
  millions for an audio chunk that keeps decoding past its end). The campaign
  builds force-include `src/fuzz/fuzz_quiet.h` into `smacker.c`, which turns
  every `fputs()`, `fprintf()` and `perror()` on `stderr` into a branch on
  `VERBOSE`: the call, its FILE lock and its copy into the stream buffer never
  happen. That was 60% of the exec time on such inputs; measured over a
  campaign's queue, 11-21% less in total. `fuzz2` and `fuzz_cov` keep the library's
  calls; for them the harness points glibc's `stderr` at an `fopencookie()`
  stream that drops everything (`init_common()` in `fuzz_utils.h`), so the
  calls cost no syscall. Sanitizer reports write to fd 2 directly and are
  unaffected. `VERBOSE=1` keeps the library's messages in every build - in a
  triage log they say which check rejected the input.
* **`afl-showmap`/`afl-cmin` abort against the msan build** ("Fork server
  crashed with signal 6") even though `afl-fuzz` drives it fine. Corpus tooling
  always uses the `fast` build.
* **`afl-cmin` needs `@@`.** Without a file argument the input goes through
  AFL's shared-memory path, which the AFLDriver target only honours under
  `afl-fuzz`; under showmap it runs on an empty buffer and the corpus collapses
  to one file.
* **Crash inputs are never minimized** — the repo's bug reports keep original
  artifact bytes.
