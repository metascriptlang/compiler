// bug155 — a destructured parameter bound nothing
//
// Symptom:    `function f({ a, b }: P)` failed with `Undefined variable 'b'` in every shape
//             (function, arrow, method, export, two patterns) on both backends; a stray global of
//             the same name was resolved instead. Found by Neon's React-style components.
//
// Root cause: parseParamList skipped the pattern (skipDestructurePattern) and named the parameter
//             `_destructure`, so the pattern never reached the checker.
//
// Fix:        the parser keeps the pattern, names the parameter `_destr<N>` and prepends
//             `const <pattern> = _destr<N>;` to the body (an expression-bodied arrow becomes a
//             block returning the expression), so the existing DestructuringDecl path binds and
//             lowers it on both backends.

interface P155 { a: number; b: string; }
interface P2_155 { a?: number | null; b: string; }
type Acc155<T> = distinct (() => T);
interface Q155 { count: Acc155<number>; label: string; }

function f155({ a, b }: P155): string { return b + a.toString(); }
function g155({ a = 5, b: bb }: P2_155): string { return bb + a.toString(); }
const h155 = ({ a }: P155): number => a * 2;
function each155(cb: (p: P155) => number): number { return cb({ a: 20, b: "x" }); }
function k155({ a }: P155, { b }: P155): string { return b + a.toString(); }
class C155 { m({ a }: P155): number { return a + 10; } }
function r155({ count, label }: Q155): string { return label + (count + 1).toString(); }
export function Counter155({ label, count }: { label: string; count: number }): string { return label + ":" + count.toString(); }
function capture155({ b }: P155): () => string { return () => b + "!"; }

test "bug155: a function binds the pattern from the annotated parameter" {
	assert f155({ a: 1, b: "x" }) === "x1";
}

test "bug155: a default fills a missing field and a rename binds the alias" {
	assert g155({ b: "y" }) === "y5";
	assert g155({ a: 2, b: "z" }) === "z2";
}

test "bug155: arrows, annotated and contextually typed" {
	assert h155({ a: 4, b: "q" }) === 8;
	const viaExpr = each155(({ a }) => a + 1);
	const viaBlock = each155(({ a, b }) => { return a + b.length; });
	assert viaExpr === 21;
	assert viaBlock === 21;
}

test "bug155: two patterns, a method and an exported function" {
	assert k155({ a: 7, b: "l" }, { a: 8, b: "r" }) === "r7";
	const c = new C155();
	assert c.m({ a: 1, b: "m" }) === 11;
	assert Counter155({ label: "n", count: 3 }) === "n:3";
}

test "bug155: an accessor field read through the pattern is the value" {
	const q: Q155 = { count: (() => 41) as Acc155<number>, label: "n=" };
	assert r155(q) === "n=42";
}

test "bug155: a destructured field survives capture by a returned closure" {
	const say = capture155({ a: 0, b: "hey" });
	assert say() === "hey!";
}
