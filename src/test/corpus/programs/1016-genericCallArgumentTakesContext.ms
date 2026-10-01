// Parity program — a generic call passed as an argument takes the
// destination for a type parameter its own arguments leave unbound; a
// call argument with a type of its own keeps it.
//
// @stdout: inner fail|2|outer fail|deep|0 1|5|3
// @exit: 0

class Box<T> { v: T; constructor(v: T) { this.v = v; } }
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function pick<T>(a: T, b: T): T { return a; }
function make<T>(): T[] { return []; }
function three(): int32 { return 3; }

const out: string[] = [];

function nested(x: number): Result<Result<number, string>, string> {
	if (x < 0) return Result.err("outer fail");
	if (x == 0) return Result.ok(Result.err("inner fail"));
	return Result.ok(Result.ok(x));
}

function deeper(): Result<Result<Result<number, string>, string>, string> {
	return Result.ok(Result.ok(Result.err("deep")));
}

const a = nested(0);
if (a.ok) { const inner = a.value; if (!inner.ok) out.push(inner.error); }
const b = nested(2);
if (b.ok) { const inner = b.value; if (inner.ok) out.push(`${inner.value}`); }
const c = nested(-1);
if (!c.ok) out.push(c.error);
const d = deeper();
if (d.ok) { const mid = d.value; if (mid.ok) { const low = mid.value; if (!low.ok) out.push(low.error); } }

const xs: string[] = pick(make(), ["a"]);
const ys: string[] = pick(["a"], make());
out.push(`${xs.length} ${ys.length}`);

const r: Result<Box<int64>, string> = Result.ok(one(5));
if (r.ok) out.push(`${r.value.v}`);

const n: int64 = pick(three(), 1);
out.push(`${n}`);
console.log(out.join("|"));
