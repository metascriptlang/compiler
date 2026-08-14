// nim-guard: `try f() catch v` types as the JOIN of the ok type and the catch value
//
// INVARIANT (reference sem.nim:138 `commonType`): an expression with branches
//   takes the common type of those branches. `checkTryExpr` discarded the catch
//   value's type and always returned the Result's ok type, so
//   `try divide(1,0) catch null` typed as int32 and the null was coerced to the
//   value type — the error path silently produced 0 instead of null.
// NIM-REF: §1 "TryExpr catch join" — DIVERGE-INCOMPLETE -> SAME, SCOPED.
//   Only a NULLABLE widening of the ok type is carried (`T`, `Maybe<T>`, `T|null`
//   pointer form). A genuinely different catch type (`catch "s"` on Result<int32,_>)
//   still reports today's loud C diagnostic rather than a half-lowered union.
//
// WHAT IT CATCHES: RED pre-fix on the value-type arm — `n` came back 0, not null
//   (0 and null share a C representation, so the discriminating arm is an ok
//   result whose VALUE is 0: pre-fix `z === null` is true and throws). The
//   ok-path, ref-type, same-type and never-catch arms pin what must NOT change.

type IR = Result<int32, string>;

class Tok { kind: int32 = 0; }

function divide(a: int32, b: int32): IR {
	if (b === 0) return Result.err("boom");
	return Result.ok(a / b);
}

function getTok(ok: boolean): Result<Tok, string> {
	if (ok) return Result.ok(new Tok());
	return Result.err("no tok");
}

function boom(): int32 { throw "fail"; }

function main(): void {
	const n = try divide(1, 0) catch null;
	if (n !== null) { throw "GUARD RED: value-type `catch null` did not yield null"; }

	const z = try divide(0, 5) catch null;
	if (z === null) { throw "GUARD RED: a legitimate ok value of 0 is indistinguishable from the null catch"; }
	if (z! !== 0) { throw "GUARD RED: ok-zero lost its value"; }

	const m = try divide(8, 2) catch null;
	if (m === null) { throw "GUARD RED: ok path lost its value"; }
	if (m! !== 4) { throw "GUARD RED: ok path wrong value"; }

	const t = try getTok(false) catch null;
	if (t !== null) { throw "GUARD RED: ref-type `catch null` did not yield null"; }
	const t2 = try getTok(true) catch null;
	if (t2 === null) { throw "GUARD RED: ref ok path lost its value"; }

	const same = try divide(10, 2) catch 0;
	if (same !== 5) { throw "GUARD RED: same-type catch changed"; }

	const v = try divide(9, 3) catch boom();
	if (v !== 3) { throw "GUARD RED: never-catch changed"; }

	console.log("tryCatchJoin ok");
}
main();
