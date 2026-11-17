import { compileToC } from "../helpers";

function emitted(source: string): string {
	const r = compileToC(source);
	return r.ok ? r.value : "";
}

function copiesByDuplicating(c: string): boolean {
	return (c.contains("msBigIntCopy(") || c.contains("msBigIntIncref("))
		&& !c.contains("msIncref(");
}

test "E2E C: a bigint pushed twice is duplicated, not counted" {
	const c = emitted("function both(a: bigint, out: bigint[]): void { out.push(a); out.push(a); }");
	assert copiesByDuplicating(c);
}

test "E2E C: a nullable bigint pushed twice is duplicated, not counted" {
	const c = emitted("function both(a: bigint | null, out: (bigint | null)[]): void { out.push(a); out.push(a); }");
	assert copiesByDuplicating(c);
}

test "E2E C: a struct's copy hook duplicates its bigint field" {
	const c = emitted("struct P { v: bigint; n: int32; }\nfunction both(p: P, out: P[]): void { out.push(p); out.push(p); }");
	assert copiesByDuplicating(c);
}

test "E2E C: a struct's copy hook duplicates its nullable bigint field" {
	const c = emitted("struct P { v: bigint | null; }\nfunction both(p: P, out: P[]): void { out.push(p); out.push(p); }");
	assert copiesByDuplicating(c);
}

test "E2E C: a tuple's copy hook duplicates its bigint element" {
	const c = emitted("function both(t: [bigint, int32], out: [bigint, int32][]): void { out.push(t); out.push(t); }");
	assert copiesByDuplicating(c);
}

test "E2E C: an element read kept past its array is duplicated" {
	const c = emitted("function first(xs: bigint[], out: bigint[]): void { const x = xs[0]; out.push(x); out.push(x); }");
	assert copiesByDuplicating(c);
}
