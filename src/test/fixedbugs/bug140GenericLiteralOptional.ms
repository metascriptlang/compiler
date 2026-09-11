// bug140 — an object literal that omits an optional field is rejected by a generic call
// Symptom: `For({ each, children })` with `fallback?` omitted fails "got __anon…, expected object"; through a
//          `createComponent<P>` wrapper the older binary accepted it while HEAD rejected it.
// Root cause: the literal was restamped with the instantiated formal but never constructed against it, and the
//             stale self-typed struct was compared with the layout-prefix relation.
// Fix: re-check the literal against the instantiated formal in tryInstantiateGenericCallee and report a type
//      parameter bound to two types inside one argument.

function For140<T>(props: { each: () => T[]; children: (item: T) => string; fallback?: string | null }): string {
	const fb = props.fallback;
	return props.children(props.each()[0]) + (fb == null ? "" : fb);
}

function ForIdx140<T>(props: { each: () => T[]; children: (item: T, index: () => number) => string; fallback?: string | null }): string {
	return props.children(props.each()[1], () => 1);
}

function createComponent140<P>(Comp: (props: P) => string, props: P): string {
	return Comp(props);
}

const xs140: number[] = [7, 8];

test "bug140: a generic call accepts a literal that omits an optional field" {
	assert For140({ each: () => xs140, children: (item: number) => "item " + item.toString() }) == "item 7";
}

test "bug140: the omitted optional field reads as null" {
	assert For140({ each: () => xs140, children: (item: number) => "x", fallback: "!" }) == "x!";
	assert For140({ each: () => xs140, children: (item: number) => "x" }) == "x";
}

test "bug140: a generic function passed as a value takes the same literal" {
	assert createComponent140(For140, { each: () => xs140, children: (item: number) => "item " + item.toString() }) == "item 7";
}

test "bug140: a two-parameter callback field still binds T" {
	assert ForIdx140({ each: () => xs140, children: (item: number, i: () => number) => item.toString() + "@" + i().toString() }) == "8@1";
}
