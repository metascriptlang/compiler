// bug008 — unifyType didn't bridge Union<T, Null> ↔ Maybe<X>
//
// Symptom:    Generic function `<T>(x: T | null)` called WITHOUT
//             explicit type-arg `<T>` and a typed witness arg failed
//             type inference for value-type T:
//                 const w: Color | null = null;
//                 fn(w);   // T not inferred → "undefined variable" or
//                          // failed instantiation
//             Caller goes through `inferGenericReturn` → `unifyType`
//             which compared formal param type `Union<GP, Null>` (decl-
//             time, GP not Maybe-wrappable) against arg type
//             `Maybe<Color>` (resolveAnnotation canonical). Different
//             kinds (Union vs Struct) → unifyType bailed at `formal.kind
//             !== concrete.kind` → T never bound.
//
// Root cause: `unifyType` in src/checker/types.ms didn't recognize
//             Maybe<X> (Struct with IsMaybe) and Union<T, Null> as
//             representations of the same logical type. The two forms
//             coexist by design (value-type uses wrapper struct,
//             pointer-type uses bare nullable pointer) but unifyType
//             treated them as structurally unrelated.
//
// Fix:        Before the structural same-kind check, add a bridge case:
//             when one side is `Union<T, Null>` 2-member and the other
//             is `Maybe<X>` (Struct + IsMaybe + non-null typeReturn),
//             peel Maybe to its inner X and unify against the non-Null
//             member of the Union. Symmetric for both directions
//             (formal vs concrete).

enum Color { Red, Green, Blue }

function takeWitness<T>(x: T | null): int32 {
	return 99;
}

test "bug008: T inferred from typed witness var (value T)" {
	const w: Color | null = null;
	const r = takeWitness(w);
	assert r === 99;
}

test "bug008: T inferred from inline TypeAssertion (value T)" {
	const r = takeWitness(null as Color | null);
	assert r === 99;
}
