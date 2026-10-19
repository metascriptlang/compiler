// nim-guard: the cycle collector's work on a live graph that does not die is bounded, and
// garbage cycles made after that are still collected while the program runs.
//
// Reference: a collection that frees less than half of what it touched raises the threshold
// by half, up to `high(int) div 4`, and an effective one lowers it by a third
// (lib/system/orc.nim:493-501), so the collections over a live cyclic graph grow with the
// log of the registrations, not with their number.
// Proven red with the growth capped at 16384 in runtime/drc.c `msOrcCollect`, the policy
// before this guard: 248 collections. The garbage half is proven red with growth jumping
// straight to the bound: no collection runs before exit.
//
// RED MEANS the threshold policy drifted; run /trace-nim on msOrcCollect's adaptive
// threshold against orc.nim collectCycles.

@passC("-DMSGC_ORC_STATS");
@compile("./fixtures/orcCollections.c");

import { msTestOrcCollections, msTestOrcFreed } from "./fixtures/orcCollections.h";

class RingNode {
	next: RingNode | null = null;
	id: int32 = 0;
}

class Slot {
	held: RingNode | null = null;
}

class Pair {
	other: Pair | null = null;
}

const ringSize = 100000;
const passes = 40;
const maxCollections = 40;
const garbagePairs = 400000;
const minFreedWhileRunning = 400000;

function touchLiveRing(nodes: RingNode[]): void {
	const slot = new Slot();
	for (let p = 0; p < passes; p++) {
		for (let i = 0; i < ringSize; i++) {
			slot.held = nodes[i];
			slot.held = null;
		}
	}
}

function makeGarbagePairs(): void {
	for (let i = 0; i < garbagePairs; i++) {
		const a = new Pair();
		const b = new Pair();
		a.other = b;
		b.other = a;
	}
}

function main(): void {
	const nodes: RingNode[] = [];
	for (let i = 0; i < ringSize; i++) {
		const node = new RingNode();
		node.id = i;
		nodes.push(node);
	}
	for (let i = 0; i < ringSize; i++) nodes[i].next = nodes[(i + 1) % ringSize];

	touchLiveRing(nodes);
	const collections = msTestOrcCollections();
	if (collections < 0) {
		console.log("GUARD-SKIP the collector is not linked under this gc");
		return;
	}
	if (collections > maxCollections) {
		throw new Error(`${collections} collections over a live ring of ${ringSize}, more than ${maxCollections}`);
	}

	makeGarbagePairs();
	const freed = msTestOrcFreed();
	if (freed < minFreedWhileRunning) {
		throw new Error(`${freed} cyclic cells freed while running after ${garbagePairs} garbage pairs, fewer than ${minFreedWhileRunning}`);
	}
	console.log(`${collections} collections, bounded; garbage collected while running`);
}
main();
