// nim-guard: Vec<T> =copy detaches the payload (unique ownership)
//
// INVARIANT (Nim =copy for seq): assigning a value-array always allocates a
//   fresh payload — mutating the copy never shows through the source, and
//   scope exit destroys each side's own payload exactly once.
// NIM-REF: seq =copy hook; classify.ms hook names must exist in
//   runtime/core/system.h (classifyArray names msArrayUint8Copy et al).
//
// WHAT IT CATCHES: (a) the uint8 copy hook missing from the runtime —
//   pre-2026-08-23 every `const c = v` on Vec<uint8> died at C compile with
//   "call to undeclared function 'msArrayUint8Copy'" (proven red 2026-08-23);
//   (b) an aliasing copy (source mutates with the copy); (c) a non-detaching
//   copy double-frees the shared payload at scope exit under the san lane.
//
// RED MEANS: classifyArray's hook names drifted from the runtime macros, or
//   the copy stopped allocating fresh. C backend only — JS assignment copy
//   is a known open hole (⑥), do not port this guard to JS until it lands.

import { exit } from "std/process";

function main(): void {
    const v: Vec<uint8> = [1, 2, 3];
    const c = v;
    c[0] = 9;
    if (v[0] !== 1) { exit(1); }
    if (c[0] !== 9) { exit(2); }
    const e: Vec<uint8> = [];
    const e2 = e;
    if (e2.length !== 0) { exit(3); }
    const vn: Vec<number> = [1, 2];
    const cn = vn;
    cn[0] = 7;
    if (vn[0] !== 1) { exit(4); }
    console.log("vecValueCopyDetach ok");
}
main();
