// nim-guard: overwriting an array or map variable stores the new container before it releases
// the old one, so an onDestroy run by releasing an old element that reads the variable finds the
// new container, never the dying one.
//
// Nim releases a seq before it stores (liftdestructors.nim fillSeqOp, attachedSink:
// `move(x, y, destroy)`); NIM-REF records the forced divergence, because releasing first let
// such a hook call a closure whose environment was already freed (ASan heap-use-after-free on
// MS and on the Nim 2.2.2 twin under arc and orc).
//
// RED MEANS an overwrite of that container shape releases the old elements while the variable
// still names them: the hook read its own tag (1) instead of the new element's (2), or crashed.

class Witness {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void {
		if (watching) {
			watching = false;
			seen = reader();
		}
	}
}

struct Slot {
	w: Witness | null;
}

let watching = false;
let seen: int32 = 0;
let failures = "";
let reader: () => int32 = (): int32 => 0;

function watch(read: () => int32): void {
	reader = read;
	seen = 0;
	watching = true;
}

function check(what: string): void {
	watching = false;
	if (seen != 2) failures = `${failures}${what}: the hook read ${seen}, want 2; `;
}

function tagOf(w: Witness | null): int32 {
	return w == null ? -2 : w.tag;
}

let ws: Witness[] = [];
let spareWs: Witness[] = [];
let fns: (() => int32)[] = [];
let spareFns: (() => int32)[] = [];
let slots: Slot[] = [];
let spareSlots: Slot[] = [];
let byKey: Map<int32, Witness> = new Map<int32, Witness>();

function witnessed(tag: int32): () => int32 {
	const w = new Witness(tag);
	return (): int32 => w.tag;
}

function mapOf(tag: int32): Map<int32, Witness> {
	const m = new Map<int32, Witness>();
	m.set(0, new Witness(tag));
	return m;
}

function firstWitness(): int32 {
	return ws.length == 0 ? -2 : ws[0].tag;
}

function firstSlot(): int32 {
	return slots.length == 0 ? -2 : tagOf(slots[0].w);
}

function refArraySink(): void {
	ws = [new Witness(1)];
	watch(firstWitness);
	ws = [new Witness(2)];
	check("ref array sink");
}

function refArrayCopy(): void {
	ws = [new Witness(1)];
	spareWs = [new Witness(2)];
	watch(firstWitness);
	ws = spareWs;
	check("ref array copy");
}

function closureArraySink(): void {
	fns = [witnessed(1)];
	watch((): int32 => fns.length == 0 ? -2 : fns[0]());
	fns = [witnessed(2)];
	check("closure array sink");
}

function closureArrayCopy(): void {
	fns = [witnessed(1)];
	spareFns = [witnessed(2)];
	watch((): int32 => fns.length == 0 ? -2 : fns[0]());
	fns = spareFns;
	check("closure array copy");
}

function structArraySink(): void {
	slots = [{ w: new Witness(1) }];
	watch(firstSlot);
	slots = [{ w: new Witness(2) }];
	check("struct array sink");
}

function structArrayCopy(): void {
	slots = [{ w: new Witness(1) }];
	spareSlots = [{ w: new Witness(2) }];
	watch(firstSlot);
	slots = spareSlots;
	check("struct array copy");
}

function mapSink(): void {
	byKey = mapOf(1);
	watch((): int32 => tagOf(byKey.get(0)));
	byKey = mapOf(2);
	check("map sink");
}

refArraySink();
refArrayCopy();
closureArraySink();
closureArrayCopy();
structArraySink();
structArrayCopy();
mapSink();
if (failures != "") throw new Error(failures);
console.log("containers stored before release");
