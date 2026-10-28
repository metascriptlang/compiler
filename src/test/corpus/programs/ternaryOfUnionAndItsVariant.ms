// @stdout: false true true true 4 1
// note: a conditional whose arms are a union and one of its narrowed variants joins back to the union, so the result can be tested on the discriminant again; both arm orders, for a Result and for a struct match union.

function make(n: int32): Result<void, string> {
	if (n > 0) { return Result.ok(null); }
	return Result.err("neg");
}
function pick(recorded: Result<void, string>): Result<void, string> {
	const flushed = recorded.ok ? make(1) : recorded;
	if (!flushed.ok) { return flushed; }
	return Result.ok(null);
}
function swapped(recorded: Result<void, string>): Result<void, string> {
	const flushed = recorded.ok ? recorded : make(1);
	if (!flushed.ok) { return flushed; }
	return Result.ok(null);
}

enum Kind { Dot, Square }
struct Shape = match (kind: Kind) {
	Kind.Dot => {},
	Kind.Square => { side: int32 },
};
function side(s: Shape, other: Shape): int32 {
	const t = s.kind == Kind.Dot ? other : s;
	return t.kind == Kind.Square ? t.side : 1;
}
function dotFirst(s: Shape, other: Shape): int32 {
	const t = s.kind == Kind.Square ? s : other;
	return t.kind == Kind.Square ? t.side : 1;
}
const sq: Shape = { kind: Kind.Square, side: 4 };
const dot: Shape = { kind: Kind.Dot };
console.log(pick(make(-1)).ok, pick(make(1)).ok, swapped(make(-1)).ok, swapped(make(1)).ok, side(dot, sq), dotFirst(dot, dot));
