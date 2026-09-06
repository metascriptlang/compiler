// nim-guard: a literal type is identified by its VALUE, in both relations
//
// INVARIANT (Nim): value-carrying types compare by value, not by kind.
//   `sameTypeAux` (types.nim:1224) sends `tyRange` through `sameValue`, and
//   `typeRel` (sigmatch.nim) inherits that identity — a candidate taking `1..5`
//   does not match an argument of `6..10` merely because both are ranges.
// NIM-REF: rows 76/80 record MS running `isAssignable` and `typeRelation` where
//   Nim runs one relation. `isAssignable` (:368/:384) and `sameType` (:651) both
//   compare literal types by value; `typeRelation`'s same-kind dispatch fell
//   through to its `_ => Exact` catch-all, so EVERY pair of string literals — and
//   every pair of boolean literals — scored Exact against each other.
//   -> DIVERGE-UNINTENTIONAL, same class as [typeRelationStringUnion].
//
// WHAT WENT WRONG: two overloads separated only by literal type both scored
//   Exact, so overload resolution reported "Ambiguous call" and no program could
//   dispatch on a literal type at all.
//
// WHAT IT CATCHES: restoring the catch-all for literal kinds. Pre-fix this file
//   does not build ("Ambiguous call to overloaded function"), so the guard goes
//   red at compile time.

function pick(a: "row"): int32 { return 1; }
function pick(a: "column"): int32 { return 2; }

function flag(b: true): int32 { return 10; }
function flag(b: false): int32 { return 20; }

// A literal argument must still satisfy the widened parameter.
function widened(s: string): int32 { return 30; }
function widenedBool(b: boolean): int32 { return 40; }

export function main(): void {
	const r: "row" = "row";
	const c: "column" = "column";
	const t: true = true;
	const f: false = false;

	const pr = pick(r);
	const pc = pick(c);
	console.log("pick row=" + pr.toString() + " column=" + pc.toString());
	if (pr != 1) { throw "GUARD RED: string-literal overload picked the wrong candidate"; }
	if (pc != 2) { throw "GUARD RED: string-literal overload picked the wrong candidate"; }

	const ft = flag(t);
	const ff = flag(f);
	console.log("flag true=" + ft.toString() + " false=" + ff.toString());
	if (ft != 10) { throw "GUARD RED: boolean-literal overload picked the wrong candidate"; }
	if (ff != 20) { throw "GUARD RED: boolean-literal overload picked the wrong candidate"; }

	const w = widened(r);
	console.log("widened=" + w.toString());
	if (w != 30) { throw "GUARD RED: string literal no longer widens to string"; }

	const wb = widenedBool(t);
	console.log("widenedBool=" + wb.toString());
	if (wb != 40) { throw "GUARD RED: boolean literal no longer widens to boolean"; }

	console.log("literalTypeDispatch ok");
}

main();
