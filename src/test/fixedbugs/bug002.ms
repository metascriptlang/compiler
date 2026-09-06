// bug002 — Ref<GI<MatchType>> loses monomorphized name
//
// Symptom:  When a generic match-type DU is wrapped in Ref (heap-allocated
//           form `type Foo<T,E> = Ref<FooBody<T,E>>`), the literal codegen
//           used the BASE typeName (`FooBody`) instead of the MONO name
//           (`FooBody__number_string`). Result: a duplicate, base-named C
//           typedef + warnings about `incompatible pointer types` between
//           `FooBody*` and `FooBody__number_string*`. Latent; could become
//           hard link errors with stricter toolchains.
//
// Root cause: In `safeAddrOf` / ObjectLiteral construction
//             (src/codegen/c/expressions.ms), `peelToStructOrUnion` walked
//             through GenericInstance to the inner Union body, but the body
//             carried the BASE typeName. The fix anchors `namingType` on the
//             outer GI (which `getTypeDesc` correctly mono-mangles).
//
// Fix:        When peeling Ref<GI<...>>, remember the inner GI and use that
//             as `namingType` for `getTypeDesc`. Falls back to the inner
//             union body if no GI present.

enum BodyK { Ok, Err }
type Body<T, E> = match (kind: BodyK) {
	BodyK.Ok => { value: T },
	BodyK.Err => { error: E },
};
type BodyRef<T, E> = Ref<Body<T, E>>;

function makeOk(v: number): BodyRef<number, string> {
	return { kind: BodyK.Ok, value: v };
}

function makeErr(e: string): BodyRef<number, string> {
	return { kind: BodyK.Err, error: e };
}

test "bug002: Ref<GI<MatchType>> ok variant — mono name preserved" {
	// Pre-fix: codegen emitted `Body*` instead of `Body__number_string*`,
	// triggering pointer-type warnings + potential link issues.
	const r = makeOk(99);
	if (r.kind == BodyK.Ok) {
		assert r.value == 99;
	}
}

test "bug002: Ref<GI<MatchType>> err variant — mono name preserved" {
	const r = makeErr("boom");
	if (r.kind == BodyK.Err) {
		assert r.error == "boom";
	}
}
