// A spawn thunk that assigns a captured parameter is refused like a `let` capture
//
// INVARIANT (ULTRALOCK V4/T3): a captured binding the task rebinds is one slot shared with the
//   parent thread. A parameter carries no Mutable flag, so the capture walk judges it by the write.
//
// WHAT IT CATCHES: `p = new C(i)` inside the thunk compiled clean while the parent read `p.v`;
//   with the slab off under ASan it was a heap-use-after-free in 1 to 5 of 5 runs.
//
// RED MEANS: a written parameter crosses the spawn boundary unchecked again, at the thunk's own
//   level, one nested routine deeper, or through a compound assignment.
//
// GUARD-JS
// GUARD-CHECK-FAIL mutable variable 'rebound' cannot be captured by spawn
// GUARD-CHECK-FAIL mutable variable 'nestedRebound' cannot be captured by spawn
// GUARD-CHECK-FAIL mutable variable 'counted' cannot be captured by spawn

class C { v: int32; constructor(v: int32) { this.v = v; } }

async function assignedInThunk(rebound: C): Promise<int32> {
	const h = spawn(() => {
		for (let i = 0; i < 100000; i += 1) rebound = new C(i); // GUARD-REFUSED
		return 1;
	});
	let s: int32 = 0;
	for (let i = 0; i < 100000; i += 1) s = (s + rebound.v) % 1000;
	return await h + s;
}

async function assignedInNestedArrow(nestedRebound: C): Promise<int32> {
	const h = spawn(() => {
		const swap = (): void => { nestedRebound = new C(2); }; // GUARD-REFUSED
		swap();
		return 1;
	});
	const seen = nestedRebound.v;
	return await h + seen;
}

async function compoundAssigned(counted: number): Promise<number> {
	const h = spawn(() => {
		counted += 1; // GUARD-REFUSED
		return 1;
	});
	const seen = counted;
	return await h + seen;
}

console.log(await assignedInThunk(new C(1)));
console.log(await assignedInNestedArrow(new C(1)));
console.log(await compoundAssigned(1));
