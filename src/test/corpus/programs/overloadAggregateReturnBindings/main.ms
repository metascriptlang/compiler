// @stdout: arity=1,1 1,2 4,5 | kinds=7 7 | swapped=3,4 7 | params=7,0 5,5 5,9 | try=34
// note: a call to an overloaded function whose result is an aggregate (struct, Result), bound by a
// `const`/`let` initializer or by `try`, calls the overload it resolved to. Each group varies one
// axis: arity, which overload returns the aggregate, the parameter types, a Result return under
// `try`, and the overload set living in another module. Pinned on C and JS; the SBF build of the
// same shapes is src/test/guard/overloadAggregateReturnLinks.ms.

import { Pair, mk } from "./lib";

struct Wide { x: int32; y: int32; z: int32; w: int32; }

function kind(n: int32): Pair { return { a: n, b: 0 }; }
function kind(n: int32, m: int32): int32 { return n + m; }

function swapped(n: int32): int32 { return n; }
function swapped(n: int32, m: int32): Pair { return { a: n, b: m }; }

function fold(n: int32): Pair { return { a: n, b: 0 }; }
function fold(g: Wide): Pair { return { a: g.x + g.w, b: g.y + g.z }; }
function fold(s: string): Pair { return { a: s.length as int32, b: 9 }; }

function load(x: int32): Result<Pair, string> { return Result.ok({ a: x, b: 1 }); }
function load(x: int32, y: int32): Result<Pair, string> { return Result.ok({ a: x, b: y }); }

function loadSum(): Result<int32, string> {
	const p = try load(3, 4);
	return Result.ok(p.a * 10 + p.b);
}

function main(): void {
	const a = mk(1);
	const b = mk(1, 2);
	let c = mk(1, 2, 3);
	const arity = `arity=${a.a},${a.b} ${b.a},${b.b} ${c.a},${c.b}`;

	const k = kind(3, 4);
	const kp = kind(7);
	const kinds = `kinds=${kp.a} ${k}`;

	const s = swapped(3, 4);
	const sp = swapped(7);
	const swaps = `swapped=${s.a},${s.b} ${sp}`;

	const big: Wide = { x: 1, y: 2, z: 3, w: 4 };
	const f1 = fold(7);
	const f2 = fold(big);
	const f3 = fold("hello");
	const params = `params=${f1.a},${f1.b} ${f2.a},${f2.b} ${f3.a},${f3.b}`;

	const r = loadSum();
	const tried = r.ok ? `try=${r.value}` : "try=err";
	console.log(`${arity} | ${kinds} | ${swaps} | ${params} | ${tried}`);
}

main();
