// @xfail(raiser): raiser `typeof` of a union value yields the value, not its type name — `const t = f ? 7 : "x"; typeof t` prints `x` on v0.2.55, the same with no try
// Parity program — `try r catch v` types and lowers like the ternary `r.ok ? r.value : v`.
// Axes: a `Result<void, E>` in statement position with a value catch and a call catch, and bound
// to a const; a catch of another type joining into a union; null (Maybe), the same type, a
// wider number, a string and a class.
//
// @stdout: caught void-err|caught void-bound|union n s|maybe null|num -1 1.5 7|str w []|class null 3|after
// @exit: 0

const out: string[] = [];
function touch(ok: boolean): Result<void, string> {
	if (!ok) return Result.err("no");
	return Result.ok(null);
}
function num(ok: boolean): Result<int32, string> {
	if (!ok) return Result.err("no");
	return Result.ok(7);
}
function word(ok: boolean): Result<string, string> {
	if (!ok) return Result.err("no");
	return Result.ok("w");
}
class Box { v: int32 = 3; }
function box(ok: boolean): Result<Box, string> {
	if (!ok) return Result.err("no");
	return Result.ok(new Box());
}
function note(tag: string): void { out.push(`caught ${tag}`); }

try touch(true) catch false;
try touch(false) catch false;
try touch(false) catch note("void-err");
try touch(true) catch note("void-ok");
const vr = try touch(false) catch note("void-bound");

const u1 = try num(true) catch "x";
const u2 = try num(false) catch "x";
out.push(`union ${typeof u1 == "string" ? "s" : "n"} ${typeof u2 == "string" ? "s" : "n"}`);
const m = try num(false) catch null;
out.push(`maybe ${m == null ? "null" : "v"}`);
const same = try num(false) catch -1;
const widened = try num(false) catch 1.5;
out.push(`num ${same} ${widened} ${try num(true) catch 1.5}`);
out.push(`str ${try word(true) catch ""} [${try word(false) catch ""}]`);
const b = try box(false) catch null;
out.push(`class ${b == null ? "null" : "box"} ${(try box(true) catch null)!.v}`);
out.push("after");
console.log(out.join("|"));
