// bug131 — member read on a flow-narrowed union-storage local
//
// Symptom:    after a discriminant guard narrows a local whose declared type
//             is a DU, reading a variant field failed to compile: clang
//             reported "member reference type '<Union>' is not a pointer".
//             The discriminant read in the guard itself compiled fine, and
//             the same read on a PARAMETER worked — only value-storage
//             locals were broken. C backend only; JS accepted the program.
// Root cause: src/codegen/c/expressions.ms (narrowed-variant member access)
//             chose the access operator by asking isPointerType of the
//             flow-NARROWED nodeType — a variant is Ref-repr, so it always
//             said "pointer" and emitted `local->vN.field` against a local
//             that is the union struct BY VALUE. The emitted base name and
//             its C storage follow the DECLARED symbol, so pointer-ness must
//             be asked of symbolType, never the narrowed type: narrowing
//             selects which variant slot is read, it does not move the base
//             into pointer storage. (The guard read worked because at the
//             guard the flow type is still the union itself.)
// Fix:        ask isPointerType(idSym.symbolType) instead of the narrowed
//             nodeType; params keep their `->` via isIndirectParam as before.
//
// Guarded end-to-end by corpus/programs/259-narrowedUnionMemberRead.ms.

interface B131Circle { kind: "circle"; r: float64; }
interface B131Square { kind: "square"; w: float64; }
type B131Shape = B131Circle | B131Square;

// Built through a call so the value is a real union-storage local, not a
// foldable literal.
function b131pick(circle: boolean): B131Shape {
	if (circle) {
		const c: B131Circle = { kind: "circle", r: 3.0 };
		return c;
	}
	const q: B131Square = { kind: "square", w: 5.0 };
	return q;
}

test "bug131: member read on a narrowed local" {
	const s = b131pick(false);
	if (s.kind === "square") {
		assert s.w === 5.0;
	}
}

test "bug131: member read in the else branch" {
	const s = b131pick(true);
	if (s.kind === "square") {
		assert false;
	} else {
		assert s.r === 3.0;
	}
}

test "bug131: several reads off the same narrowed local" {
	const s = b131pick(false);
	if (s.kind === "square") {
		assert s.w + s.w === 10.0;
	}
}

test "bug131: narrowed local member read still works on parameters" {
	const s = b131pick(false);
	const viaParam = (x: B131Shape): float64 => {
		if (x.kind === "square") {
			return x.w;
		}
		return 0.0;
	};
	if (s.kind === "square") {
		assert s.w === viaParam(s);
	}
}
