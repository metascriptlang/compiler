// Bug: generic functions with an omitted (inferred) return type kept
// TypeKind.Inferred on the monomorphized instance's return all the way to
// codegen — the decl-side checkFunctionDecl applies ctx.inferredReturn to
// the symbol, but instantiateGenericFunction never seeded or applied it:
// the re-checked body's returns mutated a stale inferredReturn slot and the
// instance shipped with an unresolved return. C failed with "internal:
// unresolved type (kind=48) reached codegen"; JS folded values to
// "<object>". Reproducer shape:
//
//     function dup<T>(x: T) { return x; }
//     const n = dup<int32>(42);   // C: kind=48 error, JS: n === "<object>"
//
// Fix: instantiateGenericFunction seeds bodyCtx.inferredReturn from the
// instance type before the body re-check and applies the inferred return
// afterwards, mirroring checkFunctionDecl (including the void fallback for
// never-returning bodies).

function dup<T>(x: T) { return x; }

test "bug119: mono instance adopts the inferred return type" {
	const n = dup<int32>(42);
	assert n == 42;
	const s = dup<string>("hey");
	assert s == "hey";
}

function pickSecond<T>(a: T, b: T) { return b; }

test "bug119: inferred return flows through multi-param generics" {
	const v = pickSecond<float64>(1.5, 2.5);
	assert v == 2.5;
}
