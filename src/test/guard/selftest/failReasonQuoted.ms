// SELFTEST-RED exit=1: selftest reason names the invariant
// A probe that exits non-zero after a GUARD-FAIL line must be red with that line's reason, not only its exit status.

import { exit } from "std/process";

console.log("GUARD-FAIL selftest reason names the invariant");
exit(1);
