# Incremental-compilation cases

Each `<name>.txt` is a sequence of edits that `src/test/ic/run.ms` drives through one warm build
session (`msc build main.ms --hcr --watch-replay`) and checks against a cold build of the same
sources at every step. The format follows the reference compiler's metamorphic IC suite.

- `#!FILE <path>` starts a module; its text runs to the next directive. `main.ms` is the build root
  and the first step must write it. A later step's `#!FILE` rewrites that module.
- `#!STEP <attrs>` builds the files written so far. Attributes are `;`-separated:
  `expect: <stdout>` (a cold `msc run main.ms` prints it, `\n` for a newline), `noop`
  (nothing rechecked or relowered), `body-edit` (only the edited modules rechecked),
  `iface-edit` (an importer rechecked too), `modules: <n>` (rechecked count), `rechecked: <a.ms
  b.ms>` (exactly these project modules rechecked, sorted), `lowered: <n>`,
  `rebuilt` (the session may fall back to a full rebuild), `fails: <text>` (warm and cold both
  fail, cold with that text).
- `#!XFAIL <why>` marks a case red today for the named reason; the runner fails it once it
  turns green, so the marker is dropped with the fix.
- Lines before the first `#!FILE` describe the case.

At every step the warm build's C must equal the cold build's byte for byte, and a step after the
first must stay warm unless it says `rebuilt`.
