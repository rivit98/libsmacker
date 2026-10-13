# Standalone program and report

## 7. The standalone program

- Public API only: `#include "smacker.h"`, no harness headers. The artifact is
  the file as is; the seek target, if the crash needs the seek, is its last
  byte modulo the frame count.
  Spell out the calls the crash needs (`smk_open_memory()`, `smk_enable_all()`
  with every track the crash needs, `smk_first()`/`smk_next()`, ...).
- Keep the original input bytes and do not minimize: minimizers drift to other
  bugs. The whole program lives in `main()`. Write a small input as an inline
  array; build a large one in a `static unsigned char buf[N]` inside `main()`
  with `memcpy()` for literal stretches and `memset()` for runs.
- Build it on the clean upstream tree with exactly the commands that go into
  the report, and take the output from that run.

## 8. The report

`reportN.md` at the repository root, next free N: check existing `report*.md`
files and the `reportN.md` comments in `src/fuzz/main.c`. One issue per file.

It contains exactly these parts and nothing else. No description, no analysis,
no suggested fix:

````markdown
Hi, I found the following problem while fuzzing libsmacker.

## Code version
`<full upstream commit hash>`

## How to reproduce
```c
<standalone program>
```

Compile with <AddressSanitizer | MemorySanitizer | UndefinedBehaviorSanitizer> and run:
```
<library build commands>
<reproducer compile command>
./repro
```

## Output
```
<sanitizer output>
```
````

Compile commands, run from the root of the clean upstream tree. libsmacker is
a single source file, so the reproducer compiles it in directly - no library
build, nothing that upstream's autotools setup has to agree with:

- **ASAN**, also for UBSAN findings and leaks:
  ```
  clang -g -O1 -DNDEBUG -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I . -o repro repro.c smacker.c
  ```
- **MSAN**:
  ```
  clang -g -O1 -DNDEBUG -fsanitize=memory -fsanitize-memory-track-origins=2 \
        -fno-omit-frame-pointer -I . -o repro repro.c smacker.c
  ```

Trimming the output:

- Drop `BuildId`, the `0x...` addresses in frames, the shadow-byte block, and
  the `__libc_start_*` / `_start` frames.
- Make paths relative to the libsmacker source root.
- Keep the frames that name library source.
- For deep recursion, keep a few frames and write
  `[ ... frame N repeats to the end of the stack ... ]`.

## Title and the gh command

The issue title does not go in the file. Suggest one in your reply, in the form
`<area>: <what breaks> <when>`, and put the command that files the issue above
the `RF()` in `main.c`, as a comment - always, for every report:

```c
// gh issue create --repo greg-kennedy/libsmacker --body-file reportN.md --title "<area>: <what breaks> <when>"
```

Do not run it. Once the user files the issue, the comment is replaced by the
issue URL.
