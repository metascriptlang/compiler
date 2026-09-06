# Windows Host Traps (paid for 2026-09-05)

Only relevant when the dev box is Windows. On macOS/Linux hosts, skip.

- **Corpus `MSC=` must name a `.exe`.** The runner spawns the subject through
  `cmd.exe`, which refuses extension-less binaries — an extension-less MSC
  once produced an 863-fail corpus run where every cell said "build failed"
  for a reason that had nothing to do with the compiler.
- **msc spawns clang with the target's directory as cwd.** A stale
  `runtime/` / `std/` / `vendor/` tree parked next to your targets (a
  temp-dir graveyard from an older session did exactly this: an old
  `dispatch.h` without `cancelled`, while the repo's copy was current) wins
  the quoted-include search and produces header errors that "can't be true".
  Delete stale support trees near targets FIRST; never start by reading
  compiler source.
- **pwsh `git show X | Set-Content` corrupts non-ASCII source** (one mangled
  char broke a `fit.ms` export list). In a throwaway worktree use
  `git checkout -- <file>` instead; in the main tree see the Git Rules in
  `CLAUDE.md`.
- **`Start-Process` ExitCode is sometimes empty even after `-Wait`** — judge
  runs by artifacts (test totals in the log, built binaries), not
  `$p.ExitCode`.
- Strip ANSI before grepping logs: ``-replace "`e\[[0-9;]*m",""``.
- The SAN lane needs libasan; scoop MinGW has none (`cannot find -lasan`), so
  `MSCORPUS_SAN=1` is host-blocked until a toolchain with ASan arrives.
