// bug114 — aliased-condition De Morgan collapsed the reference to one side
//
// Symptom:    after `const b = ty !== null && ty.kind === K.X; if (b) return;`
//             every later member read of `ty` silently compiled to
//             getDynamicField(ty, "kind") on both backends, so enum dispatch
//             fell through to the default; a fresh `ty !== null` guard did
//             not repair it. No diagnostic anywhere.
// Root cause: narrowType's `&&`-false and `||`-true union paths shortcut
//             "one side didn't narrow" by returning the OTHER side — the
//             intersection shortcut applied to a union — so `Ty | null`
//             collapsed to `null` on the fall-through path
//             (checker/flow.ms &&-false / ||-true legs).
// Fix:        union absorption — if either side leaves the type unnarrowed
//             the union is the original type. The reference
//             (narrowTypeByBinaryExpression) builds the union with no
//             shortcut; the intersection legs keep their chaining.

enum B114Kind { Number, Uint64, Int64 }
class B114Ty { kind: B114Kind; }

function b112AndFalse(ty: B114Ty | null): string {
	const b = ty != null && ty.kind == B114Kind.Number;
	if (b) return "num";
	if (ty != null && ty.kind == B114Kind.Uint64) return "u64";
	return "plain";
}

function b112UnrelatedRight(ty: B114Ty | null, flag: boolean): string {
	const b = ty != null && flag;
	if (b) return "flagged";
	if (ty != null && ty.kind == B114Kind.Uint64) return "u64";
	return "plain";
}

function b112OrTrue(x: B114Ty | null): string {
	const b = x == null || x.kind == B114Kind.Number;
	if (b) {
		if (x != null && x.kind == B114Kind.Number) return "num";
		return "isnull";
	}
	return "other";
}

test "bug114: fall-through of an aliased && exit keeps the union wide" {
	const tu: B114Ty = { kind: B114Kind.Uint64 };
	assert b112AndFalse(tu) == "u64";
}

test "bug114: unrelated right conjunct does not collapse the reference" {
	const tu: B114Ty = { kind: B114Kind.Uint64 };
	assert b112UnrelatedRight(tu, false) == "u64";
}

test "bug114: aliased || in the true branch keeps both arms" {
	const tn: B114Ty = { kind: B114Kind.Number };
	assert b112OrTrue(tn) == "num";
}
