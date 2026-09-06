// bug130 — a flow-narrowed reference passed back to a union formal
//
// Symptom:    a value whose declared type is a DU, narrowed by a discriminant
//             guard and then passed to a function taking that same DU, failed
//             to compile: clang reported "indirection requires pointer operand"
//             on the argument. C backend only; JS accepted the same program.
// Root cause: src/checker/fit.ms — widenVariantToUnion decided the conversion
//             from the expression's CURRENT (flow-narrowed) type, so a plain
//             reference looked like a variant that must be widened. It wrapped
//             the argument in HiddenSubConv + HiddenDeref and rebuilt the union
//             from the variant, while the value's STORAGE was the union all
//             along and the parameter wanted its address.
// Fix:        a reference whose declared type is already the tag union is an
//             identity fit — no conversion node, and the argument keeps the
//             union as its node type so codegen takes its address as usual.
//             Conversions follow the declared type, never the narrowed one.
//
// Guarded end-to-end by corpus/programs/258-narrowedUnionArg.ms (all lanes).

interface B130Circle { kind: "circle"; r: float64; }
interface B130Square { kind: "square"; w: float64; }
type B130Shape = B130Circle | B130Square;

function b130area(s: B130Shape): float64 {
	return match (s.kind) {
		"circle" => s.r * s.r,
		"square" => s.w * s.w,
	};
}

// Built through a call so the value is not constant-folded away — the bug only
// surfaces when the argument is a real union-storage local.
function b130pick(circle: boolean): B130Shape {
	if (circle) {
		const c: B130Circle = { kind: "circle", r: 3.0 };
		return c;
	}
	const q: B130Square = { kind: "square", w: 4.0 };
	return q;
}

test "bug130: guard-narrowed reference passes to a union formal" {
	const s = b130pick(true);
	assert s.kind == "circle";
	assert b130area(s) == 9.0;
}

test "bug130: narrowing in the else branch is the same shape" {
	const s = b130pick(false);
	if (s.kind == "circle") {
		assert false;
	} else {
		assert b130area(s) == 16.0;
	}
}

test "bug130: narrowed reference used twice in one expression" {
	const s = b130pick(true);
	if (s.kind == "circle") {
		assert b130area(s) + b130area(s) == 18.0;
	}
}

test "bug130: narrowed reference re-bound to a union local" {
	const s = b130pick(false);
	if (s.kind == "square") {
		const again: B130Shape = s;
		assert b130area(again) == 16.0;
	}
}
