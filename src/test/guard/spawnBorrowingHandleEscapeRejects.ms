// nim-guard: the handle of a spawn that borrows from its scope never leaves that scope.
//
// INVARIANT (ULTRALOCK T1): a task that reads a reference its parent lends is joined when
//   the parent's scope exits, so its handle is refused in every shape that outlives the
//   scope: a return, a field, a module variable, a call argument, a container reached
//   through a parameter, a constructor argument and an object literal.
//
// WHAT IT CATCHES: an escape shape slipping past the check; the handle would then name a
//   task the scope exit already cancelled or joined. Isolated tasks take the same shapes
//   and run (corpus spawnFuturesHeldByMapAndSet, spawnIsolatedOutlivesItsScope).
//
// RED MEANS: one of the shapes compiled.
//
// GUARD-CHECK-FAIL returning it would let the handle outlive that join
// GUARD-CHECK-FAIL storing it in 'this.pending' would let the handle outlive that join
// GUARD-CHECK-FAIL storing it in 'parked' would let the handle outlive that join
// GUARD-CHECK-FAIL passing it to 'keep' would let the handle outlive that join
// GUARD-CHECK-FAIL passing it to 'byKey.set' would let the handle outlive that join
// GUARD-CHECK-FAIL passing it to a constructor would let the handle outlive that join
// GUARD-CHECK-FAIL storing it in an object would let the handle outlive that join

class Data { v: int32 = 5; }

function read(d: Readonly<Data>): int32 { return d.v; }

let parked: Promise<int32> | null = null;

function keep(p: Promise<int32>): void {
	parked = p;
}

class Holder {
	pending: Promise<int32> | null = null;
	constructor(p: Promise<int32> | null) { this.pending = p; }

	start(d: Data): void {
		this.pending = spawn(() => read(d));
	}
}

function returned(d: Data): Promise<int32> {
	const h = spawn(() => read(d));
	return h;
}

function stored(d: Data): void {
	parked = spawn(() => read(d));
}

function passed(d: Data): void {
	keep(spawn(() => read(d)));
}

function intoParameter(byKey: Map<int32, Promise<int32>>, d: Data): void {
	byKey.set(1, spawn(() => read(d)));
}

function intoConstructor(d: Data): Holder {
	return new Holder(spawn(() => read(d)));
}

function intoObject(d: Data): int32 {
	const o = { p: spawn(() => read(d)) };
	return 0;
}

const d = new Data();
console.log(`${await returned(d)}`);
