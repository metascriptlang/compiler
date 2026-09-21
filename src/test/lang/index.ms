// Aggregate for the lang/ tier — one entry per file, so a lane can run the tier
// with a single `msc test`. NOT wired into the gate's `tests` lane yet: the tier
// type-checks clean, but `lang/syntax.ms` does not build
// (~/metascript/.inbox/compiler/2026-09-21-optional-chain-into-string-local-in-a-test-block.md).

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
