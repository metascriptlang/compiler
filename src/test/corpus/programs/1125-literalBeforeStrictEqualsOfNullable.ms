// Parity program — a string literal on the left of === or !== against a nullable
// string compares like the literal on the right: the derived operator found no
// overload for the pair and dropped the comparison, so JS crashed the compiler
// (or folded the comparison to false) on a call argument.
//
// @stdout: true false false true true
// @stdout: true false
// @exit: 0

function mk(k: int32): string | null { return k > 0 ? "s" : null; }
function show(x: boolean): string { return x ? "true" : "false"; }

const m = mk(1);
const n = mk(0);
console.log("s" === m, "s" === n, "s" !== m, "t" !== n, "s" == m);
console.log(show("s" === m), show("s" === n));
