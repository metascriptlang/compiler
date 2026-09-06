// explicitTargGenericBody — explicit type-args on calls inside a generic body
// survive instantiation when the call's ARGUMENTS contain nested calls.
//
// Parser kept explicit `<T, ...>` in a single pending slot consumed by the NEXT
// CallExpr to FINISH parsing — a nested call in the argument list finished first
// and stole it, leaving the outer call's typeArg empty. Checker re-checks of
// instantiated generic bodies then fell back to the location-keyed side channel,
// which still holds the PRE-substitution string ("T, string") → resolveAnnotation
// ("T") in a scope with no T → "Unresolved type 'T'" (neon flow For<number>).
// Fix: parseCallExpr captures the pending slot at ENTRY (before parsing args).

function egMap<A, B>(xs: A[], f: (a: A) => B): B[] {
	const out: B[] = [];
	for (const x of xs) { out.push(f(x)); }
	return out;
}

function egEach(): number[] { return [10, 20, 30]; }

function egWrap<T>(props: { each: () => T[] }): string {
	const m = egMap<T, string>(props.each(), (x) => "v");
	let s = "";
	for (const e of m) { s = s + e; }
	return s;
}

function egId<U>(v: U): U { return v; }

function egOuter<T>(xs: T[]): number {
	const ys = egMap<T, number>(egId<T[]>(xs), (x) => 1);
	return ys.length;
}

test "explicit T type-arg survives instantiation with nested-call args" {
	assert egWrap<number>({ each: egEach }) == "vvv", "wrap";
}

test "nested explicit type-args: inner call steals nothing from outer" {
	assert egOuter<number>([1, 2, 3]) == 3, "outer";
}
