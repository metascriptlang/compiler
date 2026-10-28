// @stdout: 10 100 2
// @stdout: 20 100 2
// @stdout: 30 100 2
// @stdout: 10:10 20 30 100
// @stdout: 20:10 20 30 100
// @stdout: 30:10 20 30 100
// @stdout: temps 10 7 8
// @stdout: default 7 7 8
// note: a for-of over a Proxy keeps its own list and index out of reach of the loop body, so names the author declares (even `$i` and `$items`) read the author's values, in a nested loop too. The compiler's own temps are named so no declaration of the author's (even `__dflt_1`) collides with them, beside a for-of and a default argument.
class Tr<T> {
	get<K extends keyof T>(t: T, k: K): T[K] { return Reflect.get(t, k); }
}
const xs: int32[] = [10, 20, 30];
const p = new Proxy(xs, new Tr<int32[]>());
const $i = 100;
const $items: int32[] = [1, 2];
for (const x of p) console.log(x, $i, $items.length);
for (const x of p) {
	let seen = "";
	for (const y of p) seen = seen + String(y) + " ";
	console.log(String(x) + ":" + seen + String($i));
}
let __dflt_1 = 7;
let __dflt_2 = 8;
for (const x of p) if (x == 10) console.log("temps", x, __dflt_1, __dflt_2);
function withDefault(a: int32, b: int32 = a + 1): int32 { return a + b; }
function three(): int32 { return 3; }
console.log("default", withDefault(three()), __dflt_1, __dflt_2);
