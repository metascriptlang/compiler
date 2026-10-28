// @stdout: true true true
// @stdout: x 1 3 7 -1 5 bad
struct Point { x: int32; }
enum Fail { Bad }
function direct(): Result<string | null, string> { return Result.ok("x"); }
function intUnion(): Result<int32 | null, string> { return Result.ok(1); }
function delta(a: int32, b: int32): Result<int32 | null, Fail> { return Result.ok(a - b); }
function pick(s: string | null): Result<string | null, Fail> {
	if (s === null) { return Result.ok(null); }
	return Result.ok(s);
}
function point(): Result<Point | null, string> { return Result.ok({ x: 5 }); }
function balance(found: boolean): Result<int64 | null, string> {
	if (!found) { return Result.ok(null); }
	const value: int64 = 7;
	return Result.ok(value);
}
function failed(): Result<string | null, string> { return Result.err("bad"); }
const a = direct();
const i = intUnion();
const b = pick("q");
const c = point();
console.log(`${a.ok} ${i.ok} ${b.ok}`);
const d = delta(5, 2);
const e = balance(true);
const f = balance(false);
const g = failed();
console.log(`${a.ok ? a.value : "-"} ${i.ok ? i.value : 0} ${d.ok ? d.value : 0} ${e.ok ? e.value : 0} ${f.ok && f.value === null ? -1 : 0} ${c.ok && c.value !== null ? c.value.x : 0} ${g.ok ? "ok" : g.error}`);
