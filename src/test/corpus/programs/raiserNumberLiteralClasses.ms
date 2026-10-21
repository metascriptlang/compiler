// @stdout: 1 2 5000000001 1 2 4 1.5
// @stdout: 0.5
// note: a number literal type takes the register class of its base type: float, int32 and int64 literals, a literal union, a nullable literal.
// @exit: 0

type Half = 0.5;
type One = 1;
function pick(f: boolean): One | 2 { return f ? 1 : 2; }
let h: Half = 0.5;
let o: One = 1;
let big: 5000000000 = 5000000000;
const arr: Array<One | 2> = [1, 2, 1];
let sum = 0;
for (const v of arr) sum += v;
console.log(h * 2, o + 1, big + 1, pick(true), pick(false), sum, h + o);
let n: Half | null = null;
if (n === null) n = 0.5;
console.log(n);
