// @stdout: 6
// @stdout: 27
// @stdout: 9
// note: a compiler temp the checker hoists at module scope (a bound default argument, a for-of over a Proxy) is declared again on every pass of a top-level loop. The declaration leaves the value it already holds to the next assignment, which releases it, so nothing it held earlier stays alive at exit.
class Box {
	v: int32 = 0;
}
function make(v: int32): Box {
	const b = new Box();
	b.v = v;
	return b;
}
function pick(a: Box, b: Box = a): int32 { return a.v + b.v; }
let total = 0;
for (let i = 0; i < 3; i += 1) total += pick(make(i));
console.log(total);

class Tr<T> {
	get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); }
}
const xs: int32[] = [1, 2];
const p = new Proxy(xs, new Tr<int32[]>());
let sum = 0;
let round = 0;
while (round < 3) {
	for (const x of p) for (const y of p) sum += x * y;
	round += 1;
}
console.log(sum);

let deep = 0;
for (const a of p) for (const b of p) for (const c of p) if (a == b && b == c) deep += a * 4 - c;
console.log(deep);
