// @stdout: field closures collected true
// @stdout: array closures collected true
// @stdout: nested closures collected true
// @skip-js: onDestroy does not run on JS
// note: a cycle that runs through a closure's env (an object holding a closure that captures the object) is collected while the program runs like any other cycle, so at most the roots of the next collection stay; the field, array and one-level-deeper positions each close the cycle through the env.

const N: int32 = 1000;
const LEFT_FOR_NEXT_COLLECTION: int32 = 256;

class Holder { f: (() => int32) | null = null; id: int32 = 0; }
class Many { fs: (() => int32)[] = []; id: int32 = 0; }
class Outer { inner: Holder | null = null; id: int32 = 0; }

let holders: int32 = 0;
let manys: int32 = 0;
let outers: int32 = 0;
function onDestroy(this h: Holder): void { holders += 1; }
function onDestroy(this m: Many): void { manys += 1; }
function onDestroy(this o: Outer): void { outers += 1; }

function fieldCycle(i: int32): int32 {
	const h = new Holder();
	h.id = i;
	h.f = (): int32 => h.id;
	return h.f!();
}

function arrayCycle(i: int32): int32 {
	const m = new Many();
	m.id = i;
	m.fs.push((): int32 => m.id);
	return m.fs[0]();
}

function nestedCycle(i: int32): int32 {
	const o = new Outer();
	o.id = i;
	const inner = new Holder();
	inner.f = (): int32 => o.id;
	o.inner = inner;
	return o.inner!.f!();
}

let sum: int64 = 0;
for (let i: int32 = 0; i < N; i++) sum += fieldCycle(i);
console.log(`field closures collected ${holders >= N - LEFT_FOR_NEXT_COLLECTION}`);
for (let i: int32 = 0; i < N; i++) sum += arrayCycle(i);
console.log(`array closures collected ${manys >= N - LEFT_FOR_NEXT_COLLECTION}`);
for (let i: int32 = 0; i < N; i++) sum += nestedCycle(i);
console.log(`nested closures collected ${outers >= N - LEFT_FOR_NEXT_COLLECTION}`);
