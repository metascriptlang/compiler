// nim-guard: storing a closure over the one that holds the last reference to an object with
// onDestroy writes the new closure before it releases the old one, so the hook, reading the
// destination, calls the new closure.
//
// Nim liftdestructors.nim atomicClosureOp, attachedSink and attachedAsgn, isCyclic branch: assign,
// then release the old env. Proven red on 2c7d9781a, which released first: the hooks read
// -1, -2 and -3, the old closures; with a second capture the sink is a heap-use-after-free
// under ASan.
//
// RED MEANS a closure store (global sink, lifted field copy or lifted field sink) releases
// the old value before the destination holds the new one.

class Witness {
	via: int32 = 0;
	onDestroy(): void {
		observed = this.via == 1 ? current() : slot.f();
	}
}

struct Slot {
	f: () => int32;
}

let observed: int32 = 0;
let current: () => int32 = (): int32 => 0;
let slot: Slot = { f: (): int32 => 0 };

function witnessed(via: int32, old: int32): () => int32 {
	const w = new Witness();
	w.via = via;
	return (): int32 => w.via == 0 ? 0 : old;
}

function makeSlot(n: int32): Slot {
	return { f: (): int32 => n };
}

function expect(what: string, want: int32): void {
	if (observed != want) throw new Error(`${what}: the hook read ${observed}, want ${want}`);
	observed = 0;
}

current = witnessed(1, -1);
current = (): int32 => 42;
expect("closure sink", 42);

slot = { f: witnessed(2, -2) };
const other: Slot = { f: (): int32 => 43 };
slot = other;
expect("closure field copy", 43);

slot = { f: witnessed(2, -3) };
slot = makeSlot(44);
expect("closure field sink", 44);
console.log("closures stored before release");
