// nim-guard: a `U[]` LOCAL-VARIABLE annotation, with U bound to a function type,
// resolves to Array<function> — not to a bare function.
//
// INVARIANT: monomorphizing a generic body substitutes the type-param name into
//   string annotations textually (monoConcreteTypeName + monoSubstAnnotation).
//   A function type's literal `() => number` MUST be parenthesized as
//   `(() => number)` so a following `[]` binds to the whole function, giving
//   `(() => number)[]` = Array<fn>. Without parens the string is `() => number[]`,
//   which re-parses as `() => (number[])` — a FUNCTION returning number[].
// NIM-REF: §1 "Monomorph annotation roundtrip: parenthesize compound type literals"
//   — DIVERGE-UNINTENTIONAL -> SAME. Nim substitutes on PType nodes (no string
//   precedence hazard); MS's string roundtrip must parenthesize compound types,
//   mirroring the precedent already set for anonymous unions.
//
// WHAT IT CATCHES: any generic `f<U>` whose body has a `const x: U[]` (or param-
//   position U[] only via a local) annotation collapses to `function` when U is a
//   function type. RED = build failure "Return type mismatch ... expected Array,
//   got function". Proven RED on the pre-fix binary; GREEN post-fix.
//
// No RC balance directive — the signal is build-failure / wrong return type.

function collectG<U>(make: (i: number) => U): U[] {
	const out: U[] = [make(0), make(1)];
	return out;
}

function main(): void {
	const arr = collectG<() => number>((i) => () => i * 10);
	if (arr.length !== 2) { throw "GUARD RED: U[] length wrong"; }
	if (arr[0]() !== 0) { throw "GUARD RED: elem 0 wrong"; }
	if (arr[1]() !== 10) { throw "GUARD RED: elem 1 wrong"; }
	console.log("genericFnArrayAnnot ok");
}
