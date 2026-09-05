// bug132 — hook prototypes and definitions disagreed when a function forced
// the union before the variant's interface declaration was processed
//
// Symptom:    a program whose DU variants carry a managed field (string)
//             failed to compile with clang "conflicting types for
//             'Variant__Copy/Destroy/WasMoved'": the forward prototype said
//             Variant__Copy(Variant__*) while the lifted definition said
//             Variant__Copy(Union_v0*). Reached whenever a FUNCTION is
//             emitted before the variant's `interface` declaration — most
//             commonly silently, because lambda lifting PREPENDS lifted
//             functions (and env structs) ahead of every declaration
//             (lambdaLifting): any closure over a DU with string-bearing
//             variants tripped it. C backend only.
// Root cause: src/codegen/c/types.ms genUnionType Phase 1a cached the
//             variant struct's typeKey ("object:<identity>") → the anonymous
//             slot name. That key is also genInterfaceDecl's idempotency
//             gate, so the standalone variant struct body was silently
//             dropped; DRC hook definitions then took their parameter type
//             from the hijacked cache while the prototypes derive from the
//             hook name — order-dependent name/type mismatch.
// Fix:        a variant DECLARED in this module (cname registered by the
//             pass-1 declaration walk) resolves through its own typedef via
//             getTypeDesc instead of being cached under the slot name — the
//             body is emitted, hooks/prototypes/decl agree regardless of
//             statement order. Anonymous variants keep the structural slot
//             sharing that cache was designed for.
//
// Guarded end-to-end by corpus/programs/260-liftedFnBeforeUnionVariant.ms.

interface B132C { kind: "c"; label: string; r: float64; }
interface B132S { kind: "s"; label: string; w: float64; }
type B132Sh = B132C | B132S;

// The arrow is lambda-lifted to a top-level function that lands BEFORE the
// interface declarations — the emission order that triggered the bug.
function b132mk(): B132Sh {
	const c: B132C = { kind: "c", label: "x", r: 2.0 };
	return c;
}

test "bug132: closure over a string-variant union compiles and runs" {
	const area = (x: B132Sh): float64 => {
		return match (x.kind) {
			"c" => x.r * x.r,
			"s" => x.w * x.w,
		};
	};
	const v = b132mk();
	if (v.kind === "c") {
		assert area(v) === 4.0;
		assert v.label === "x";
	}
}

test "bug132: function declared before the interface declarations" {
	const v = b132mk();
	if (v.kind === "c") {
		assert v.r === 2.0;
	} else {
		assert v.w === 0.0;
	}
}
