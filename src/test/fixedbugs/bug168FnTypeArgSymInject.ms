// bug168 — a generic bound to a FUNCTION type never injected the types inside that signature
// Symptom: `((x: int32) => HostLike)[]` calling `.map(...)` failed "in instantiation of
//          'map<function, function>': Unresolved type 'HostLike' - missing import?" — the
//          interface named only inside the function type's return never reached the generic
//          body's re-check scope.
// Root cause: injectConcreteTypeSyms walked Ref, Array, Set, Struct/Enum/Distinct,
//             GenericInstance and Union, but had no TypeKind.Function arm, so a bound type
//             argument that IS a function stopped the walk at its own node.
// Fix: walk a function type's parameters and return like any other structural type.
// Until 2026-09-16 a project whose build.ms globalImports re-exported the type masked this,
// because those exports leaked into every std module's scope.

interface Host168 { n: int32; }

function mk168(v: int32): (x: int32) => Host168 {
	return (x) => ({ n: x + v });
}

test "a std generic bound to a function type resolves the types inside its signature" {
	const fns: ((x: int32) => Host168)[] = [mk168(1), mk168(2)];
	const same = fns.map((f, i) => f);
	assert same.length == 2;
	assert same[0](10).n == 11;
	assert same[1](10).n == 12;
}

test "a function type nested in an array argument resolves too" {
	const pairs: ((x: int32) => Host168)[][] = [[mk168(5)]];
	const heads = pairs.map((p, i) => p[0]);
	assert heads.length == 1;
	assert heads[0](1).n == 6;
}
