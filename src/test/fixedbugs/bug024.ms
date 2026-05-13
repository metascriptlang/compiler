// bug024 — Generic mono missed contextual return-type binding
//
// Symptom:    `JSON.parse<Bag>` failed at C compile when Bag had array fields
//             of user-defined types (enum, alias, interface). The generic
//             helper `_jsonToIntArray<T>` / `_jsonToStructArray<T>` stayed
//             un-monomorphized (mangled as `_u0`), producing:
//                 `ColorArray ≠ msRefArray` C type mismatch
//
// Root cause: `tryInstantiateGenericCallee` (src/checker/checkExprPass.ms)
//             only had Pass 1 (arg-driven) + Pass 2 (explicit <T>) for
//             generic param binding at mono. Missing Pass 3 contextual
//             return-type binding (Nim parity — semcall.nim:777-859
//             `inheritBindings`). When macro emitted `_jsonToIntArray(jv, null)`
//             with caller-side `: Color[]` context, args alone didn't bind T
//             (null is weak), and no explicit <T> was emitted — T stayed
//             unbound, mono failed.
//
//             Additionally: MS's check-all-then-bind ordering left `null`
//             arg typed as Null primitive while mono'd formal became
//             `Maybe<Color>` (value-type T). C codegen rejected void* vs
//             struct mismatch.
//
// Fix:        Two changes in tryInstantiateGenericCallee:
//             1. Add Pass 3 contextual binding (Nim parity inheritBindings)
//             2. Add post-mono arg reconciliation: substitute formal types
//                and synthMaybeWrap null literal args for value-type T
//                Maybe<T> formals (Nim parity paramTypesMatchAux outcome
//                via deferred fixup).
//             Plus library-side decode.ms macro emits bare `null` witness
//             (no `as <Elem> | null` annotation needed).
//
// Note:      JSON.parse<T> end-to-end test deferred to run-ms (bun
//            transpiler can't narrow generic Result through macro path —
//            SERIALIZE.md Bug 17). This file tests the underlying checker
//            mechanism directly via minimal generic function calls.

enum Color { Red, Green, Blue }
type UserId = int32;

interface Item {
	name: string;
	count: int32;
}

function takeNull<T>(witness: T | null): T[] {
	return [];
}

test "bug024: Pass 3 contextual mono for value-type T (enum)" {
	// Args don't bind T (null is weak), no explicit <T>. T binds from
	// contextual return Color[]. Post-mono reconciliation wraps null to
	// Maybe<Color> for codegen.
	const r: Color[] = takeNull(null);
	assert r.length === 0;
}

test "bug024: Pass 3 contextual mono for ref-type T (interface)" {
	const r: Item[] = takeNull(null);
	assert r.length === 0;
}

test "bug024: Pass 3 contextual mono for type-alias T (UserId = int32)" {
	const r: UserId[] = takeNull(null);
	assert r.length === 0;
}
