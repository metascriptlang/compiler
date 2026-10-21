// @exit: 1
// @stdout: kept 2 3 1
// @stdout: half 1.5
// @stdout: invalid union conversion: 4 is not Narrow
// @xfail(danger): --danger drops the conversion check, so the value outside Narrow is kept instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid union conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output; src/codegen/raiser/eval.ms pins it
// note: `as` into a number-literal union is checked at run time from a plain number, from a wider literal union and from a nullable one; a binding without an annotation keeps the check. A source that is already a subset is not checked.

type Wide = 1 | 2 | 3 | 4;
type Narrow = 1 | 2 | 3;
type Half = 0.5 | 1.5 | 2.5;

function readInt(x: int32): int32 { return x; }
function readWide(x: Wide): Wide { return x; }
function readNull(x: Wide | null): Wide | null { return x; }
function readNum(x: number): number { return x; }

const a: Narrow = readInt(2) as Narrow;
const b = readWide(3) as Narrow;
const c: Narrow | null = readNull(1) as Narrow | null;
const up: Wide = a as Wide;
console.log("kept", a, b, c, up == 2);
console.log("half", readNum(1.5) as Half);
const d = readWide(4) as Narrow;
console.log("bad", d);
console.log("unreachable");
