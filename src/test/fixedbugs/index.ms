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
import "./bug004";
import "./bug005";
import "./bug006";
import "./bug007";
import "./bug008";
import "./bug009";
import "./bug010";
import "./bug011";
import "./bug012";
import "./bug013";
import "./bug014";
import "./bug015";
import "./bug016";
import "./bug017";
import "./bug018";
import "./bug019";
import "./bug020";
import "./bug021";
import "./bug022";
import "./bug023";
import "./bug024";
import "./bug025";
import "./bug026";
import "./bug027";
import "./bug028";
import "./bug029";
import "./bug030";
import "./bug031";
import "./bug032";
import "./bug033";
import "./bug034";
import "./bug035";
import "./bug036";
import "./bug037";
import "./bug038";
import "./bug039";
import "./bug040";
import "./bug041";
import "./bug042";
import "./bug043";
import "./bug044";
import "./bug045";
import "./bug046";
import "./bug047";
import "./bug049";
import "./bug050";
import "./bug051";
import "./bug052";
import "./bug053";
import "./bug054";
import "./bug055";
import "./bug056";
import "./bug057";
import "./bug058";
import "./bug059_mono_pending_dedup_module_blind";
import "./bug060_assert_message_expr_unwalked";
import "./bug061_maybe_carrier_bare_position";
