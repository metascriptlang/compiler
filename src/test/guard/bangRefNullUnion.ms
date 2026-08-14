// nim-guard: postfix `!` strips the null member of a POINTER-carrier union
//
// INVARIANT (reference options.nim:85-95 `SomePointer = ref | ptr | pointer |
//   proc`, `when T is SomePointer`): the two nilable carriers are different
//   REPRESENTATIONS — a value `T | null` is the Maybe struct `{ value, present }`
//   and unwraps by reading `.value` (nullableLower rule 1c), while a pointer
//   `Ref<T> | null` collapses to a bare pointer with null as the sentinel and
//   must unwrap with NO field read. The checker owes BOTH carriers the same
//   TYPE-LEVEL narrowing; it only narrowed the Maybe one, so `!` on a pointer
//   union was a no-op and the null member survived into later inference.
// NIM-REF: §1 "Value-type Maybe unwrap operators" — the pointer-carrier arm.
//
// WHAT IT CATCHES: the surviving null member poisons the next JOIN. `t!` joined
//   with a string must be a 2-member union; without the narrowing it is
//   { Tok, string, null } and codegen fails with
//   `assigning to 'msUnion_*' from incompatible type 'Tok *'`.
//   PROVEN RED on a binary with only this hunk reverted (branch-join, union-hook
//   and try-join fixes all still in) — so the RED is this narrowing, nothing else.

class Tok { kind: int32 = 7; }

function getTok(ok: boolean): Result<Tok, string> {
	if (ok) return Result.ok(new Tok());
	return Result.err("no tok");
}

function over(x: Tok): int32 { return 1; }
function over(x: string): int32 { return 2; }

function main(): void {
	const t = try getTok(true) catch null;

	if (t!.kind !== 7) { throw "GUARD RED: member access through `!` broke"; }
	if (over(t!) !== 1) { throw "GUARD RED: `!` did not pick the Tok overload"; }

	const cond = t !== null;
	const joined = cond ? t! : "fallback";
	const arrJoin = [t!, "s"];
	if (arrJoin.length !== 2) { throw "GUARD RED: array join through `!` broke"; }

	console.log("bangRefNullUnion ok");
}
main();
