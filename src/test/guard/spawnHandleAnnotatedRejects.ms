// nim-guard: a `Promise<T>` annotation does not take a spawn result out of its scope rules.
//
// INVARIANT (ULTRALOCK T1/T2): a spawn result is awaited once, in the scope
//   that created it, whether its binding is annotated `Promise<T>` or not; the
//   annotation names the same type and opts out of nothing.
//
// WHAT IT CATCHES: an annotated handle returned out of its scope or awaited
//   twice; the checker only warned, and the program then failed to compile in
//   C (`use of undeclared identifier 'f'`, 3/3).
//
// RED MEANS: one of the diagnostics stopped firing.
//
// GUARD-CHECK-FAIL affine Promise cannot be returned from a function
// GUARD-CHECK-FAIL has already been awaited and cannot be reused

class Child { v: int32; constructor(v: int32) { this.v = v; } }

function work(c: Readonly<Child>): int32 {
	let sum: int32 = 0;
	for (let r = 0; r < 1000; r += 1) sum = (sum + c.v) % 1000003;
	return sum;
}

function returnedAnnotated(): Promise<int32> {
	const c = new Child(3);
	const f: Promise<int32> = spawn(() => work(c));
	return f;
}

function awaitedTwiceAnnotated(): int32 {
	const c = new Child(3);
	const f: Promise<int32> = spawn(() => work(c));
	return (await f) + (await f);
}

console.log(awaitedTwiceAnnotated());
console.log(await returnedAnnotated());
