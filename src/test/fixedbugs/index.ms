// Regression suite — one file per fixed compiler bug.
//
// Each `bugNNN_*.ms` is a minimal repro of a SHIPPED bug. If the bug ever
// re-regresses, the corresponding test fails and points back to the original
// fix. New entries are append-only: do NOT delete or refactor old bug
// reproducers — their job is to fail if history repeats.
//
// Naming: `bugNNN_short_slug.ms` where NNN is the next free 3-digit number.
// Inside the file, the FIRST comment block is the bug citation:
//   - One-line summary
//   - Symptom (what the user observed)
//   - Root cause (one line, where the actual fix lives)
//   - Fix commit / PR (if known)
//
// The body is a `test "bugNNN: <slug>" { ... }` with the minimal repro.

import "./bug001";
import "./bug002";
import "./bug003";
