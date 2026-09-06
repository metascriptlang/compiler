// bug061 — a value-type `T | null` carrier used BARE reached codegen as a struct
//
// Symptom:    For a value type T, `T | null` is the carrier struct
//             { value, present }. Used without an unwrap it slipped past the
//             checker and hit clang:
//                 v === 1     → invalid operands ('Maybe_p0' and 'int')
//                 f(3, 7)     → called object type 'Maybe_fn_...' is not a function
//             Every explicit unwrap (`!`, `??`, `if (v !== null)`) already
//             worked — only the bare form was unguarded. Reference-typed
//             `Box | null` is immune: it collapses to a bare pointer, so no
//             carrier exists. Reached through `Map.get()` in bug010/bug047,
//             but a plain `const v: int32 | null` reproduces it just as well.
//
// Root cause: The two positions want OPPOSITE answers and both were missing.
//             tsc types `v === 1` on `number | undefined` as LEGAL (false when
//             absent), so it must LOWER — but operatorLower's isValueObject
//             gate excludes Maybe, so the comparison fell through to a raw C
//             `==` on a struct. tsc REJECTS calling a possibly-undefined
//             callee (ts2722), but checkCallExpr only validated arity for
//             TypeKind.Function and let a carrier callee pass undiagnosed.
//             (Arithmetic was already diagnosed — ts18048 parity.)
//
// Fix:        Lowering: operatorLower routes carrier equality through the
//             generated per-carrier Eq (payload wrapped into a carrier first),
//             so each operand is evaluated exactly ONCE — an inline
//             `v.present && v.value === o` would re-run a call-valued `v`
//             such as `m["k"]`. Carrier Eq is generated from the Type via a
//             new pendingCarrierEqs channel, because a synthesized carrier has
//             no symbol-table entry for ensureEq's name lookup to find.
//             Diagnostic: checkCallExpr rejects a Maybe-typed callee.
//
// The absent-vs-zero case is why the comparison cannot simply read `.value`:
// an absent carrier zero-inits its payload, so a payload-only compare would
// report `null === 0` as TRUE.

import { compileToCWithStd } from "../helpers";

function noneInt(): int32 | null { return null; }
function someInt(v: int32): int32 | null { return v; }
function noneStr(): string | null { return null; }

test "bug061: absent carrier never equals a payload" {
	assert !(noneInt() == 1);
}

test "bug061: absent carrier does not equal ZERO either" {
	assert !(noneInt() == 0);
}

test "bug061: present carrier compares on its payload" {
	assert someInt(7) == 7;
	assert !(someInt(7) == 8);
}

test "bug061: absent equals absent" {
	assert noneInt() == noneInt();
	assert !(noneInt() == someInt(0));
}

test "bug061: !== is the exact negation" {
	assert noneInt() != 0;
	assert someInt(7) != 8;
	assert !(someInt(7) != 7);
}

test "bug061: string payload routes through string equality" {
	assert !(noneStr() == "");
	assert noneStr() != "a";
}

test "bug061: the carrier side is evaluated only once" {
	const m: Map<string, int32> = new Map<string, int32>();
	m.set("k", 3);
	assert m.get("k") == 3;
	assert m["k"] == 3;
}

test "bug061: calling a possibly-null callee is rejected" {
	const src = `
type IntCmp = (a: int32, b: int32) => int32;
function main(): void {
	const m: Map<string, IntCmp> = new Map<string, IntCmp>();
	m.set("min", (a, b) => (a < b ? a : b) as int32);
	const f = m.get("min");
	console.log(f(3, 7));
}
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	assert c.error.indexOf("callee is possibly null", 0) >= 0;
}

test "bug061: unwrapping the callee makes the same call legal" {
	const m: Map<string, IntCmpB> = new Map<string, IntCmpB>();
	m.set("min", (a, b) => (a < b ? a : b) as int32);
	const f = m.get("min")!;
	assert f(3, 7) == 3;
}

type IntCmpB = (a: int32, b: int32) => int32;
