// Aggregate for the lang/ tier — one entry per file, so a lane can run the tier
// with a single `msc test`. NOT wired into the gate's `tests` lane yet: checking
// the 19 files together reports 11 type errors, and `lang/json.ms` does not build
// at all (~/metascript/.inbox/compiler/2026-09-20-enum-du-narrowing-in-test-block-reads-variant-payload.md).

import "./basics";
import "./strings";
import "./types";
import "./match";
import "./controlFlow";
import "./closures";
import "./closuresAdv";
import "./interfaces";
import "./classes";
import "./result";
import "./discrim";
import "./json";
import "./trycatch";
import "./recursion";
import "./advanced";
import "./async";
import "./syntax";
import "./whenStmt";
import "./multimod/main";
