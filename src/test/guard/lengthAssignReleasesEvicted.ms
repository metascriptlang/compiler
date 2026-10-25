// nim-guard: `arr.length = n` releases every element it evicts, whatever the element type, as
// `setLength` and `shrink` do.
//
// Nim has no length assignment: `setLen` is a generic resolved at the call, and its shrink resets
// each evicted slot through the element's destroy, last first (lib/system/seqs_v2.nim shrink).
// MS lowers `arr.length = n` to a runtime set-length helper, which releases strings and counted
// refs only; an element with any other destroy goes through std `setLength`, or `shrink` for a
// zero length, also inside a generic body.
//
// RED MEANS a length assignment evicted elements without releasing them: a line
// printed GUARD-FAIL with the element family, or the ledger shows Witness alloc > destroy at exit.
// GUARD-BALANCE Witness

import { exit } from "std/process";

let released: int32 = 0;
let failures: int32 = 0;

class Witness {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void { released += 1; }
}

struct Slot { w: Witness; tag: int32; }
struct MaybeSlot { w: Witness | null; tag: int32; }
type Pair = [Witness, int32];

function expect(family: string, want: int32): void {
	if (released != want) {
		console.log(`GUARD-FAIL ${family}: released ${released}, want ${want}`);
		failures += 1;
	}
	released = 0;
}

function witnessed(tag: int32): () => int32 {
	const w = new Witness(tag);
	return (): int32 => w.tag;
}

function closures(): void {
	const fns: (() => int32)[] = [witnessed(1), witnessed(2), witnessed(3)];
	fns.length = 0;
	expect("closure", 3);
}

function structs(): void {
	const slots: Slot[] = [{ w: new Witness(1), tag: 1 }, { w: new Witness(2), tag: 2 }];
	slots.length = 0;
	expect("struct", 2);
}

function grownStructs(): void {
	const slots: MaybeSlot[] = [{ w: new Witness(1), tag: 1 }];
	slots.length = 3;
	expect("struct, grow", 0);
	slots[2] = { w: new Witness(3), tag: 3 };
	slots.length = 1;
	expect("struct, shrink after growing", 1);
	slots.length = 0;
	expect("struct, shrink to 0 after growing", 1);
}

function unions(): void {
	const items: (Witness | string)[] = [new Witness(1), "text", new Witness(2)];
	items.length = 0;
	expect("union", 2);
}

function tuples(): void {
	const pairs: Pair[] = [[new Witness(1), 1], [new Witness(2), 2]];
	pairs.length = 0;
	expect("tuple", 2);
}

function cut<T>(items: T[], n: int32): void {
	items.length = n;
}

function inGeneric(): void {
	const slots: MaybeSlot[] = [{ w: new Witness(1), tag: 1 }, { w: new Witness(2), tag: 2 }, { w: null, tag: 3 }];
	cut(slots, 1);
	expect("struct, in a generic body", 1);
	cut(slots, 0);
	expect("struct, emptied in a generic body", 1);
}

function nested(): void {
	const rows: Witness[][] = [[new Witness(1), new Witness(2)], [new Witness(3)]];
	rows.length = 0;
	expect("nested array", 3);
}

closures();
structs();
grownStructs();
unions();
tuples();
inGeneric();
nested();
if (failures > 0) exit(1);
console.log("every evicted element released");
