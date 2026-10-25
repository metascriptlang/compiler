// nim-guard: a closure array that releases an environment on a cycle registers it as a cycle
// candidate, so the cycle is collected after a collection already found it alive.
//
// Reference: a closure's destructor releases its environment through
// nimDecRefIsLastCyclicDyn under ORC (liftdestructors.nim atomicClosureOp, :967-969, :1002-1003),
// and a seq destroys each element with that destructor (fillSeqOp).
// Proven red with runtime/core/array.c `msClosureArrayDestroy` releasing each environment
// through plain msDecref: Owner alloc=12 destroy=0 under orc. The collection that runs while the
// array holds the environment drops Owner from the roots, and the array's release never adds
// it back.
//
// RED MEANS a closure array releases its environments without registering cycle candidates;
// run /trace-nim on msClosureArrayDestroy against atomicClosureOp.
//
// GUARD-BALANCE Owner
// GUARD-BALANCE Pair

class Owner {
	cb: (() => int32) | null = null;
	n: int32 = 7;
}

class Pair {
	other: Pair | null = null;
}

function handlers(): (() => int32)[] {
	const o = new Owner();
	const f = (): int32 => o.n;
	o.cb = f;
	return [f];
}

function collectWhileHeld(): void {
	for (let i: int32 = 0; i < 1000; i += 1) {
		const a = new Pair();
		const b = new Pair();
		a.other = b;
		b.other = a;
	}
}

function main(): void {
	let s: int32 = 0;
	for (let round: int32 = 0; round < 12; round += 1) {
		const held = handlers();
		collectWhileHeld();
		s = s + held[0]();
	}
	console.log(s);
	console.log("GUARD-OK");
}
main();
