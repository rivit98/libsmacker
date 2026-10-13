#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>

#include <smacker.h>

/* VERBOSE and TC, read once by init_common() below. */
bool verbose = false;

/* The process's own stderr, for the harness's messages - see init_common(). */
FILE *real_stderr;

const char *tc_filter = NULL;
bool tc_filter_matched = false;

#define CHECK(cond) do { if (!(cond)) goto out; } while(0)

/*
 * Consume a value the harness does not inspect - and keep the call that
 * produced it. A (void) cast does not stop the compiler from deleting a
 * side-effect-free call at -O2; an asm operand does, since the value has to be
 * materialised for it.
 */
#define USE(expr) \
  do { __typeof__(expr) _use_tmp = (expr); __asm__ volatile("" : "+m"(_use_tmp)); } while (0)

char *nullterminated(const char *data, size_t size) {
  char *newdata;

  newdata = malloc(size + 1);
  memcpy(newdata, data, size);
  newdata[size] = '\0';
  return newdata;
}

void sprintf_artifact_as_hexstr(char *out, size_t out_size,
                              const char *buf, size_t buf_size)
{
    size_t pos = 0;

    for (size_t i = 0; i < buf_size; i++) {
        int written = snprintf(out + pos,
                               (pos < out_size) ? out_size - pos : 0,
                               "\\x%02x",
                               (unsigned char)buf[i]);

        if (written < 0 || (size_t)written >= out_size - pos)
            break; // truncated or full

        pos += (size_t)written;
    }

    if (pos < out_size)
        out[pos] = '\0';
    else
        out[out_size - 1] = '\0';
}

/*
 * mmap the artifact in full, so the caller sees exactly the bytes the fuzzer
 * wrote. Caller must munmap(*out_buf, return
 * value) instead of free()ing it.
 */
int read_artifact_raw(const char *filename, char **out_buf) {
  int fd = open(filename, O_RDONLY);
  if (fd < 0) {
    perror("open");
    exit(1);
  }

  struct stat st;
  if (fstat(fd, &st) < 0) {
    perror("fstat");
    exit(1);
  }
  size_t size = (size_t)st.st_size;

  if (size == 0) {
    close(fd);
    *out_buf = NULL;
    return 0;
  }

  void *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) {
    perror("mmap");
    exit(1);
  }

  *out_buf = map;
  return (int)size;
}

/*
 * The T() trampoline. Every T() test case gets @data as a private copy of the
 * input, NUL terminated at data[size] and freed once the test returns - so a
 * test that writes through the buffer corrupts neither the fuzzer's input nor
 * the next test case.
 *
 * T2() test cases get the fuzzer's buffer unchanged and must not write to it.
 */
int tc(const uint8_t *data, size_t size, void (*f)(const char *, size_t)) {
  char *d = nullterminated((const char *)data, size);
  f(d, size);
  free(d);
  return 0;
}

/*
 * Set by G() while a group runs: true when TC= named this group (or named
 * nothing), which means every member of it runs. False when TC= named
 * something else - then each member checks its own name, so TC= can still
 * select one test case inside a group.
 */
bool tc_group_all = true;

/*
 * Per-call-site selection cache: the strcmp() against TC runs once per site,
 * afterwards the decision is a byte load.
 */
#define TC_SKIP(func) ({ \
  static signed char _tc_sel = -1; \
  bool _tc_skip = false; \
  if (__builtin_expect(tc_filter != NULL, 0)) { \
    if (__builtin_expect(_tc_sel < 0, 0)) { \
      _tc_sel = strcmp(tc_filter, #func) == 0; \
      tc_filter_matched |= (bool)_tc_sel; \
    } \
    _tc_skip = !_tc_sel && !tc_group_all; \
  } \
  _tc_skip; \
})

/*
 * Run one test case. Under VERBOSE=1 a banner goes out before the call, so a
 * test case that crashes or hangs is still named - the last banner is the one
 * that died. It goes to the real stderr, clear of the RF() text the RA()
 * macros print on stdout.
 */
#define T_RUN(func, call) do { \
  if (TC_SKIP(func)) \
    break; \
  if (__builtin_expect(verbose, 0)) \
    fprintf(real_stderr, "=== Running %s ===\n", #func); \
  call; \
} while(0)

#define T(func)  T_RUN(func, tc((const uint8_t *)(data), size, func))
#define T2(func) T_RUN(func, func((const char *)(data), size))

/*
 * A test group: the unit TC= selects, and the unit fuzzer/seeds/<group>/ is
 * built for. The group is entered even when TC= names something else, because
 * what it names may be one of the members.
 */
#define G(func) do { \
  static signed char _g_sel = -1; \
  if (__builtin_expect(tc_filter != NULL, 0)) { \
    if (__builtin_expect(_g_sel < 0, 0)) { \
      _g_sel = strcmp(tc_filter, #func) == 0; \
      tc_filter_matched |= (bool)_g_sel; \
    } \
    tc_group_all = (bool)_g_sel; \
  } \
  /* A group entered only so its members can check their own names has
     nothing to announce - the member that matches announces itself. */ \
  if (__builtin_expect(verbose, 0) && tc_group_all) \
    fprintf(real_stderr, "=== Running %s ===\n", #func); \
  func((const char *)(data), size); \
} while (0)

/*
 * libsmacker reports every malformed field with fputs()/fprintf()/perror() on
 * stderr - several lines per rejected input, one write(2) each on an
 * unbuffered stream. glibc's stderr is an ordinary FILE * variable that those
 * calls read each time, so pointing it at a fopencookie() stream whose write
 * callback drops everything makes them no-ops: no formatting into a
 * descriptor, no syscall.
 *
 * Sanitizer reports are unaffected - the runtimes write(2) to fd 2 directly.
 * The harness's own messages go to real_stderr. VERBOSE keeps the library's
 * messages too: in a triage log they say which check rejected the input, and
 * smk_malloc()'s "calloc() returned NULL" is the only sign of its exit().
 *
 * The campaign binary goes further: fuzz_quiet.h, force-included into its
 * smacker.c, skips those calls altogether unless VERBOSE is set. This stream
 * is what fuzz2 and fuzz_cov rely on.
 */
static ssize_t null_write(void *cookie, const char *buf, size_t size)
{
  (void)cookie;
  (void)buf;

  return (ssize_t)size;   /* consumed everything, stored none of it */
}

static const cookie_io_functions_t null_io = {
  .read  = NULL,
  .write = null_write,
  .seek  = NULL,
  .close = NULL,
};

__attribute__((constructor)) void init_common() {
  verbose = getenv("VERBOSE") != NULL;
  tc_filter = getenv("TC");
  if (tc_filter && !*tc_filter)
    tc_filter = NULL;

  real_stderr = stderr;
  if (!verbose) {
    FILE *null_fp = fopencookie(NULL, "w", null_io);
    if (!null_fp) {
      perror("fopencookie");
      exit(1);
    }
    stderr = null_fp;
  }
}


#if defined REPRODUCER

#include <dlfcn.h>

/*
 * The non-engine entry point, shared by both binaries built without a fuzzing
 * engine: fuzz2 (the RR()/RF() reproducer) and fuzz_cov (coverage).
 *
 *   ./fuzz2 <artifact>          run one input through the harness
 *   ./fuzz2 tc3 / vc3           run a harvested test case
 *   ./fuzz_cov <file> [...]     the same replay, for llvm-cov
 *
 * An argument that can be opened is an input; anything else is looked up as a
 * test case name.
 */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

/*
 * Run one input file through the harness. Returns -1 when @path cannot be
 * opened or is not a regular file; that is the caller's signal to try the
 * argument as a test case name.
 */
int run_input_file(const char *path) {
  unsigned char *buf;
  struct stat st;
  long size;
  FILE *f;

  f = fopen(path, "rb");
  if (!f)
    return -1;

  if (fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) {
    fclose(f);
    return -1;
  }

  if (fseek(f, 0, SEEK_END) != 0 || (size = ftell(f)) < 0) {
    fclose(f);
    return -1;
  }
  rewind(f);

  buf = malloc((size_t)size + 1);
  if (!buf) {
    fclose(f);
    return -1;
  }

  if (size > 0 && fread(buf, 1, (size_t)size, f) != (size_t)size) {
    free(buf);
    fclose(f);
    return -1;
  }
  fclose(f);

  LLVMFuzzerTestOneInput(buf, (size_t)size);
  free(buf);
  return 0;
}

/*
 * Call a test case by name - the vc<n>/tc<n> functions the RA()/RF() macros
 * define. dlsym against the executable itself, which is what -rdynamic in
 * fuzz_add_harness() is for.
 */
int run_test_case(const char *name) {
  void *handle, *sym;

  handle = dlopen(NULL, RTLD_NOW);
  if (!handle) {
    printf("dlopen failed: %s\n", dlerror());
    return 1;
  }

  sym = dlsym(handle, name);
  if (!sym) {
    printf("dlsym failed: %s\n", dlerror());
    dlclose(handle);
    return 1;
  }
  dlclose(handle);

  return ((int (*)())sym)();
}

int fuzz_replay_main(int argc, char **argv) {
  int i, n = 0;

  if (argc < 2) {
    printf("Usage: %s <input-file>... | <testcase>\n", argv[0]);
    return 1;
  }

  for (i = 1; i < argc; i++) {
    if (run_input_file(argv[i]) == 0) {
      n++;
      continue;
    }
    return run_test_case(argv[i]);
  }

  fprintf(real_stderr, "%s: ran %d input(s)\n", argv[0], n);
  return 0;
}

#endif /* REPRODUCER */
