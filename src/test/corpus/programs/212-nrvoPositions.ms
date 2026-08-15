// @maxrss: 30
// @stdout: nrvo-positions acc=79
// @skip-js: migrated from native/ — JS-lane audit pending
// note: Companion to nrvo-overload: locks NRVO for struct-returning calls (overloaded operator AND plain function) in object-literal field, member-access on a call result, and deeply nested call args f(g(h())). Closure-call and method-call struct returns are exercised by the broader suite. Proves NRVO is decided per-call in emitCallExpr/genClosureCall regardless of containing position.

// Regression: a struct-returning call must use the NRVO out-param convention in
// EVERY value position. nrvoOverload.ms covers return/arg/array/ternary; this adds
// object-literal field, member-access ON a call result, and deeply nested call args
// f(g(h())) — for both an OVERLOADED operator (TAG_CALL_OVERLOAD path) and a plain
// struct-returning function. (Chained-operator operands like `a*b + c` are a SEPARATE
// pre-existing operatorLower bug, intentionally not exercised here.)

struct V { x: float32; y: float32; }

function `*`(this a: V, b: V): V { return { x: a.x * b.x, y: a.y * b.y }; }
function `*`(this a: V, b: float32): V { return { x: a.x * b, y: a.y * b }; }
function mkV(x: float32, y: float32): V { return { x: x, y: y }; }
function sumV(v: V): float32 { return v.x + v.y; }

struct Pair { p: V; q: V; }

function main(): void {
	const a = mkV(2.0, 3.0);
	const b = mkV(4.0, 5.0);
	const c = mkV(1.0, 1.0);

	const pr: Pair = { p: a * b, q: mkV(6.0, 7.0) };       // object-literal field: overloaded + plain
	const f1: float32 = sumV(pr.p) + sumV(pr.q);           // 23 + 13 = 36

	const f2: float32 = (a * b).x + mkV(9.0, 10.0).y;      // member on call result: 8 + 10 = 18

	const f3: float32 = sumV(mkV(sumV(a * b), sumV(c)));   // nested f(g(h())): mkV(23,2) → 25

	const acc: int32 = (f1 + f2 + f3) as int32;            // 36+18+25 = 79
	console.log(`nrvo-positions acc=${acc}`);
}

main();
