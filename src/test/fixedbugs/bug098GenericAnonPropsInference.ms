// Bug 098 — generic instantiation never fired when T was inferred through an
// object-literal argument (checkExpr ObjectLiteral stamped the literal with the
// generic-containing formal itself, so unifyType's identity check derived zero
// bindings), and a generic fn passed UNAPPLIED as a value arg was never
// instantiated at all. Pre-fix: loud missing-symbol C errors, plus a runtime
// segfault when the props literal omitted an optional field (P bound to the
// literal's truncated anon struct instead of the instance's declared param).
// Found by Neon's direct-emission D1 probes: createComponent(For, { ... }).

interface Out {
	v: number;
}

function inferPlain<T>(props: { v: T }): number {
	return 7;
}

test "T inferred through an inline anon-object literal instantiates" {
	assert inferPlain({ v: 1 }) === 7, "instance body must be emitted and callable";
}

function inferFnField<T>(props: { pick: (x: T) => number }): number {
	return props.pick(0 as unknown as T);
}

test "T inside a function-typed field of the literal binds and runs" {
	assert inferFnField({ pick: (x: number) => x + 1 }) === 1, "pick(0) + 1";
}

function inferMulti<T>(props: { each: () => T[]; pick: (x: T) => number }): Out {
	const arr = props.each();
	return { v: props.pick(arr[0]) };
}

test "multi-field literal with closure capture binds T once across fields" {
	const items: number[] = [1, 2, 3];
	const r = inferMulti({ each: () => items, pick: (x: number) => x + 1 });
	assert r.v === 2, "pick(items[0]) = 2, got " + r.v.toString();
}

// NOT covered here: a literal whose key order differs from the formal's field
// order ({ second: "s", first: 42 } into { first: T; second: string }). The
// name-aware unify binds T correctly, but the caller's arg validation still
// compares the literal's pre-restamp anon type and rejects LOUDLY — filed as a
// remaining facet on the §2 row. Do not bind T positionally to "fix" it.

function callWith<P>(f: (p: P) => Out, p: P): Out {
	const h = () => f(p);
	return h();
}

test "generic fn passed UNAPPLIED as a value arg gets instantiated and rebound" {
	const items: number[] = [1, 2, 3];
	const r = callWith(inferMulti, { each: () => items, pick: (x: number) => x + 1 });
	assert r.v === 2, "instance referenced by the closure must be emitted, got " + r.v.toString();
}

function withOptional<T>(props: { each: () => T[]; label?: string }): number {
	const l = props.label;
	if (l) { return props.each().length + l.length; }
	return props.each().length;
}

test "literal omitting an optional field widens P to the declared param struct" {
	const items: number[] = [4, 5];
	const r = callWith(
		(p: { each: () => number[]; label?: string }) => { return { v: withOptional(p) }; },
		{ each: () => items });
	assert r.v === 2, "omitted optional must default-init, not read past the struct, got " + r.v.toString();
}

test "explicit type args stay green (control)" {
	assert inferPlain<number>({ v: 1 }) === 7, "explicit path unchanged";
}

function directParam<T>(v: T): number { return 7; }

test "direct T param inference stays green (control)" {
	assert directParam(1) === 7, "direct-arg binding unchanged";
}
