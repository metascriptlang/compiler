// nim-guard: storing a closure over the one that holds the last reference to an object with
// onDestroy writes the new closure before it releases the old one, so the hook, reading the
// destination, finds the new closure.
//
// Nim liftdestructors.nim atomicClosureOp, attachedSink and attachedAsgn, isCyclic branch: assign,
// then release the old env. Proven red on 2c7d9781a, which released first: the hooks read
// -1, -2 and -3, the old closures; with a second capture the sink is a heap-use-after-free
// under ASan. A hook may not call a function value, so it compares the destination with the
// closure just stored.
//
// RED MEANS a closure store (global sink, lifted field copy or lifted field sink) releases
// the old value before the destination holds the new one.

class Witness {
	via: int32 = 0;
	onDestroy(): void {
		const found = this.via == 1 ? current : slot.f;
		observed = found == stored;
	}
}

struct Slot {
	f: () => int32;
}

let observed = false;
let current: () => int32 = (): int32 => 0;
let slot: Slot = { f: (): int32 => 0 };
let stored: () => int32 = (): int32 => -1;

function witnessed(via: int32, old: int32): () => int32 {
	const w = new Witness();
	w.via = via;
	return (): int32 => w.via == 0 ? 0 : old;
}

function makeClosure(n: int32): () => int32 {
	const f = (): int32 => n;
	stored = f;
	return f;
}

function makeSlot(n: int32): Slot {
	const s: Slot = { f: (): int32 => n };
	stored = s.f;
	return s;
}

function expect(what: string): void {
	if (!observed) throw new Error(`${what}: the hook found the old closure`);
	observed = false;
}

current = witnessed(1, -1);
current = makeClosure(42);
expect("closure sink");

slot = { f: witnessed(2, -2) };
const other: Slot = makeSlot(43);
slot = other;
expect("closure field copy");

slot = { f: witnessed(2, -3) };
slot = makeSlot(44);
expect("closure field sink");
console.log("closures stored before release");
