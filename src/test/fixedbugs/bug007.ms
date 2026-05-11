// bug007 — substituteType didn't canonicalize Union<T, Null> → Maybe<T>
//
// Symptom:    Generic function `<T>(x: T | null)` instantiated with a
//             value-type T (enum, primitive) produced a param type
//             `Union<T_concrete, Null>` (uncanonical), while the caller's
//             arg `null as Color | null` resolved to `Maybe<Color>`
//             through resolveAnnotation. isAssignable(Maybe<Color>,
//             Union<Color, Null>) failed because they're different kinds
//             (Struct vs Union), even though both represent the same
//             logical type `Color | null`.
//
//             User-visible error:
//                 "Argument type mismatch in 'fn' arg 0:
//                  got Maybe_Color, expected Color | null"
//
// Root cause: `substituteType` Union case in src/checker/types.ms copied
//             the Union with substituted children but never re-ran the
//             `isMaybeWrappable + createMaybeType` canonicalization that
//             `resolveAnnotation` does at user-spelling parse. At decl
//             time, generic param `T` is `GenericParam` (not Maybe-
//             wrappable, by design — we don't know if T will be value
//             or pointer yet). Post-substitution, T is concrete and the
//             canonicalization should fire, but didn't.
//
// Fix:        After substituteChildrenInPlace on a Union, check for
//             2-member [T, Null] / [Null, T] shape with T isMaybeWrappable.
//             If matched, return createMaybeType(T) instead of the
//             uncanonical Union. Mirror of resolvePass.ms:260-266.

enum Color { Red, Green, Blue }

function takeWitness<T>(x: T | null): int32 {
	return 42;
}

test "bug007: typed witness var passed to <T>(x: T | null) for value T" {
	const w: Color | null = null;
	const r = takeWitness<Color>(w);
	assert r === 42;
}

test "bug007: inline TypeAssertion witness for value T" {
	const r = takeWitness<Color>(null as Color | null);
	assert r === 42;
}
