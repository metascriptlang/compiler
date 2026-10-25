// @stdout: 1.5 2.5 4.5 3000000000 9.5 | 1.5|4.5|9.5 | 0.5 5000000000
// @exit: 0
// note: a number-literal set whose smallest member is an integer and another member has a fraction reads its payload as the joined base, on a return, a field and a parameter, with an int32 or an int64 smallest member; the raiser once typed the read as the smallest member and printed the Float payload as 0.

type Box = { v: 1 | 2.5 };

function frac(w: boolean): 1 | 1.5 { return w ? 1 : 1.5; }
function wide(w: boolean): 3000000000 | 4.5 { return w ? 3000000000 : 4.5; }
function show(v: 2 | 9.5): string { return `${v}`; }
function mixed(k: int32): int32 | float64 { return k > 0 ? k : 0.5; }
function ints(k: int32): int32 | int64 { if (k > 0) return k; const big: int64 = 5000000000; return big; }

const box: Box = { v: 2.5 };
console.log(frac(false), box.v, wide(false), wide(true), 9.5 as 2 | 9.5, "|", `${frac(false)}|${wide(false)}|${show(9.5)}`, "|", mixed(0), ints(0));
