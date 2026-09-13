// bug161 — a row arrow inside a generic component's props literal kept its pre-instantiation type
// Symptom: `createComponent(For, { each, children: (item, i) => … })` with an unannotated row
//          parameter compiled on JS but died on C with `internal: unresolved type (kind=None)
//          reached codegen`; with `(x: number, i)` the same; a fully annotated row worked.
// Root cause: the generic-call reconcile loop re-checked the props literal against the
//             instantiated formal with only the literal's own Sem flag cleared, so a nested
//             arrow (and its normalized body block) kept the types from the first pass, where
//             the field type still carried the component's generic parameter.
// Fix: re-arm nested closures and literals before the reconcile re-check, so their parameters
//      are typed by the instantiated field like any contextual arrow — but only where the raw
//      field still carried a generic parameter, and descending into a nested ObjectLiteral only
//      where the field's type really is a struct: the checker synthesizes its coercions AS
//      object literals ({ value, present } for a Maybe, { fn, env } for a closure), so a blind
//      walk strips their stamp and the re-check wraps a second time.

function comp<P>(f: (p: P) => number, props: P): number { return f(props); }
function GRow<T>(props: { each: () => T[]; children: (x: T, i: number) => number }): number { return props.children(props.each()[1], 7); }

test "bug161: unannotated row parameters take the instantiated field types" {
	const r = comp(GRow, { each: (): number[] => [1, 2], children: (x, i) => x * 10 + i });
	assert r === 27, "r=" + r.toString();
}

test "bug161: a partially annotated row keeps the annotation and types the rest" {
	const r = comp(GRow, { each: (): number[] => [1, 2], children: (x: number, i) => x * 10 + i });
	assert r === 27, "r=" + r.toString();
}

type V161 = (h: number) => number;

function idx161<T>(props: {
	each: () => T[];
	children: (item: T, index: number) => V161;
	fallback?: V161 | null;
}): number {
	const xs = props.each();
	const fb = props.fallback;
	if (fb === null) { return props.children(xs[0], 0)(1); }
	return (fb as V161)(2);
}

test "bug161: a synthesized Maybe wrap is not re-wrapped by the instantiated re-check" {
	const a = idx161<number>({
		each: () => [7, 8],
		children: (item, i) => { return (h: number): number => h + item; },
	});
	const b = idx161<number>({
		each: () => [9],
		children: (item, i) => { return (h: number): number => h + item; },
		fallback: (h: number): number => h * 100,
	});
	assert a === 8, "a=" + a.toString();
	assert b === 200, "b=" + b.toString();
}
