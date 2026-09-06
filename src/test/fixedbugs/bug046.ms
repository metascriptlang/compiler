// bug046 — tuple element access inferred as void* without a type annotation
//
// Symptom:    `const b = h.p[1]` where `p: [Ty, number]` inferred `b` as void*,
//             causing a C compile error (`assigning to 'void *' from double`)
//             or a wrong `<object>` read. Only bit when the local had NO type
//             annotation — an explicit `const b: number = h.p[1]` masked it,
//             because the annotation drove the local's type and codegen for the
//             tuple field (`._1`) was already correct.
// Root cause: checkExprPass ArrayAccess arm computed the element type via
//             getElementType(arrType), which handled Array/Span/Ptr/IndexableMap
//             but had no TypeKind.Tuple case → returned pendingType() → void*.
//             nativeLower later re-derived the right type on the rewritten
//             MemberExpr, but too late: the untyped local's symbol was already
//             void*.
// Fix:        ArrayAccess arm picks arrType.typeChildren[idx] for a literal
//             index into a Tuple, mirroring nativeLower's t[i] → t._i rewrite.

interface Bug046Ty { kind: number; }
interface Bug046Holder { p: [Bug046Ty, number]; }

test "bug046: tuple element type inferred without annotation (struct field)" {
	const t: Bug046Ty = { kind: 6 };
	const h: Bug046Holder = { p: [t, 11] };
	const a = h.p[0];
	const b = h.p[1];
	assert a.kind == 6;
	assert b == 11;
}

test "bug046: tuple element type inferred without annotation (bare local)" {
	const t: Bug046Ty = { kind: 9 };
	const p: [Bug046Ty, number] = [t, 42];
	const a = p[0];
	const b = p[1];
	assert a.kind == 9;
	assert b == 42;
}
