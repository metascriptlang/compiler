// Parity program — when the result a typed argument gives does not fit the
// destination, the destination binds the type parameter and the argument is
// converted at the call; a result that fits keeps the argument binding.
//
// @stdout: -1|4.5|3 1.5|3|65535|7 7
// @exit: 0

class Box<T> { v: T; constructor(v: T) { this.v = v; } }
interface Circle { kind: "circle"; r: float64; }
interface Square { kind: "square"; s: float64; }
type Shape = Circle | Square;
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function pick<T>(a: T, b: T): T { return a; }
function area(sh: Shape): float64 { if (sh.kind == "circle") return sh.r; return sh.s; }

function minusOne(): Result<number, string> {
	let r = 0;
	return Result.ok(r - 1);
}

function shape(): Result<Shape, string> {
	const c: Circle = { kind: "circle", r: 4.5 };
	return Result.ok(c);
}

const m = minusOne();
if (m.ok) console.log(m.value);
const s = shape();
if (s.ok) console.log(area(s.value));

const i: int32 = 3;
const u: uint16 = 65535;
const b: Box<number> = one(i);
console.log(b.v, b.v / 2);
const b64: Box<int64> = one(i);
console.log(b64.v);
const bu: Box<uint32> = one(u);
console.log(bu.v);

const power: int32 = 7;
const d: int64 = pick(power, 1);
console.log(Math.max(power, 1) as int64, d);
