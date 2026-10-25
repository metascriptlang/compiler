// nim-guard: a destroy takes each managed slot's value out, emptying the slot, before it releases
// that value, and an array is emptied before its elements are released, so an onDestroy that
// reaches the dying owner finds an empty slot, never a freed or dying one.
//
// Nim neither nils a ref slot after its destructor (liftdestructors.nim atomicRefOp,
// attachedDestructor) nor takes a seq's elements out before destroying them (fillSeqOp,
// attachedDestructor: forallElements, then destroy), and its globals are destroyed at exit
// without being nilled (cgen.nim globalDestructors). NIM-REF AN-36 records the forced divergence:
// reading such a slot from a hook read freed memory (ASan heap-use-after-free on MS).
//
// Each case is a global torn down at exit, and its hooks check what they see. Two hooks write the
// very slot that is releasing them, as an object unlinking itself would.
// RED MEANS a release left its slot naming freed memory or the object being released, or an array
// still held the elements it was releasing: the hook printed GUARD-FAIL with the case, the ledger
// aborted on a DOUBLE-DESTROY, or the program crashed.

import { exit } from "std/process";

function fail(what: string, saw: string): void {
	console.log(`GUARD-FAIL ${what}: the hook saw ${saw}`);
	failures += 1;
}

class Verdict {
	onDestroy(): void {
		if (failures > 0) exit(1);
		console.log("every released slot read empty");
	}
}

class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

class RefWitness {
	onDestroy(): void {
		const b = refHolder.box;
		if (b != null) fail("ref field released before", `box ${b.n}`);
	}
}

class RefHolder {
	witness: RefWitness | null = null;
	box: Box | null = null;
}

class StringWitness {
	onDestroy(): void {
		if (stringHolder.name != "") fail("string field released before", `'${stringHolder.name}'`);
	}
}

class StringHolder {
	witness: StringWitness | null = null;
	name: string = "";
}

class SelfUnlinker {
	onDestroy(): void {
		if (selfHolder.mine != null) {
			fail("ref field released while it still named its object", "the dying object");
			selfHolder.mine = null;
		}
	}
}

class SelfHolder {
	mine: SelfUnlinker | null = null;
}

class EnvWitness {
	n: int32 = 8;
	onDestroy(): void {
		closureHolder.fn = (): int32 => 0;
	}
}

class ClosureHolder {
	fn: () => int32 = (): int32 => 0;
}

class Item {
	kind: int32;
	constructor(kind: int32) { this.kind = kind; }
	onDestroy(): void {
		let left = -1;
		if (this.kind == 1) left = cells.refs.length;
		if (this.kind == 2) left = cells.fns.length;
		if (this.kind == 3) left = cells.slots.length;
		if (this.kind == 4) left = cells.bag.items.length;
		if (this.kind == 5) left = globalItems.length;
		if (left != 0) fail(`array of kind ${this.kind} released its elements`, `length ${left}`);
	}
}

struct Slot { item: Item; tag: int32; }
struct Bag { items: Item[]; n: int32; }

class Cells {
	refs: Item[] = [];
	fns: (() => int32)[] = [];
	slots: Slot[] = [];
	bag: Bag = { items: [], n: 0 };
}

class InlineWitness {
	onDestroy(): void {
		const b = inline.boxes[0];
		if (b != null) fail("sized array element released before", `box ${b.n}`);
	}
}

class Inline {
	witness: InlineWitness | null = null;
	boxes: (Box | null)[2] = [];
}

let failures: int32 = 0;
const verdict: Verdict = new Verdict();
let refHolder: RefHolder = new RefHolder();
let stringHolder: StringHolder = new StringHolder();
let selfHolder: SelfHolder = new SelfHolder();
let closureHolder: ClosureHolder = new ClosureHolder();
let cells: Cells = new Cells();
let globalItems: Item[] = [];
let inline: Inline = new Inline();

function holdInClosure(): void {
	const envHeld = new EnvWitness();
	closureHolder.fn = (): int32 => envHeld.n;
}

function fill(): void {
	refHolder.box = new Box(7);
	refHolder.witness = new RefWitness();
	stringHolder.name = "na" + "me".repeat(2);
	stringHolder.witness = new StringWitness();
	selfHolder.mine = new SelfUnlinker();
	holdInClosure();
	cells.refs.push(new Item(1));
	const held = new Item(2);
	cells.fns.push((): int32 => held.kind);
	cells.slots.push({ item: new Item(3), tag: 3 });
	cells.bag.items.push(new Item(4));
	globalItems.push(new Item(5));
	inline.boxes[0] = new Box(9);
	inline.witness = new InlineWitness();
}

fill();
console.log("teardown follows");
