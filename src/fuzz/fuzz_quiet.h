/*
 * Force-included (-include) into the campaign build of smacker.c only - the
 * smacker_afl library in CMakeLists.txt. Never included by main.c.
 *
 * libsmacker reports every malformed field on stderr, and some loops report
 * once per iteration: smk_render_audio() keeps decoding after its bitstream
 * runs out, two messages per sample, millions per input. init_common()'s
 * fopencookie() stream already makes those writes free of syscalls, but each
 * call still takes the FILE lock and copies the text into the stream buffer -
 * measured, 60% of the time on such inputs. These macros skip the call before
 * any of that, unless VERBOSE=1 (the harness's `verbose`), so triage logs
 * still say which check rejected an input.
 *
 * <stdio.h> comes first: function-like macros defined before it would rewrite
 * glibc's own declarations of these functions. A macro does not expand inside
 * its own expansion, so the inner fputs()/fprintf()/perror() are the real ones.
 */
#ifndef FUZZ_QUIET_H
#define FUZZ_QUIET_H

#include <stdio.h>
#include <stdbool.h>

/* Defined in fuzz_utils.h, set from VERBOSE before main(). */
extern bool verbose;

#define fputs(s, f) \
  ((f) == stderr && !verbose ? 0 : fputs((s), (f)))
#define fprintf(f, ...) \
  ((f) == stderr && !verbose ? 0 : fprintf((f), __VA_ARGS__))
#define perror(s) \
  (verbose ? perror(s) : (void)0)

#endif /* FUZZ_QUIET_H */
