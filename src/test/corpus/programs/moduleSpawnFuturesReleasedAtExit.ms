// @serial
// @stdout: nums 4000
// @stdout: strs s0s1s2
// @stdout: field 4000
// @stdout: let 5000 6000
// @stdout: one 1000
// note: an empty module-level `Promise<T>[]` bakes into a static cell, and its exit
//   teardown chose the element-less array destroy for a Promise element, so every
//   future it still held at exit was never released (SAN ledger msFuture alloc 10,
//   destroy 3 before the fix). Variants: number and string payloads,
//   a future in a class field, a module `let` reassigned once, and a single
//   `const p = spawn(..)`, which awaits through a stack slot and allocates no future.

function work(k: int32): int32 {
	let n: int32 = 0;
	for (let i = 0; i < 1000; i++) n += k;
	return n;
}

function tag(k: int32): string { return `s${k}`; }

class Holder {
	fut: Promise<int32>;
	constructor(f: Promise<int32>) { this.fut = f; }
}

const nums: Promise<int32>[] = [];
for (let w = 0; w < 4; w++) nums.push(spawn(() => work(1)));
let t: int32 = 0;
for (const p of nums) t += await p;
console.log(`nums ${t}`);

const strs: Promise<string>[] = [];
for (let w = 0; w < 3; w++) {
	const k = w;
	strs.push(spawn(() => tag(k)));
}
let s = "";
for (const p of strs) s += await p;
console.log(`strs ${s}`);

const holder = new Holder(spawn(() => work(4)));
console.log(`field ${await holder.fut}`);

let again: Promise<int32> = spawn(() => work(5));
const first = await again;
again = spawn(() => work(6));
console.log(`let ${first} ${await again}`);

const one = spawn(() => work(1));
console.log(`one ${await one}`);
