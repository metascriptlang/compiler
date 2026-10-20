// nim-guard: an annotated spawn result awaited once in its scope keeps working.
//
// INVARIANT (ULTRALOCK T1/T2): `const f: Promise<T> = spawn(...)` is the same
//   handle as the unannotated binding: awaited once it yields the task's value,
//   and a scope left before the await still joins the task.
//
// WHAT IT CATCHES: the annotation being refused, or losing the join on an
//   early exit.
//
// RED MEANS: a check error, or a wrong value.

class Child { v: int32; constructor(v: int32) { this.v = v; } }

function work(c: Readonly<Child>): int32 {
	let sum: int32 = 0;
	for (let r = 0; r < 1000; r += 1) sum = (sum + c.v) % 1000003;
	return sum;
}

function awaitedOnce(): int32 {
	const c = new Child(3);
	const f: Promise<int32> = spawn(() => work(c));
	return await f;
}

function leftEarly(quit: boolean): int32 {
	const c = new Child(3);
	const f: Promise<int32> = spawn(() => work(c));
	if (quit) return -1;
	return await f;
}

if (awaitedOnce() != 3000) { throw "GUARD RED: awaited once"; }
if (leftEarly(true) != -1) { throw "GUARD RED: early exit"; }
if (leftEarly(false) != 3000) { throw "GUARD RED: late exit"; }
console.log("GUARD-OK");
