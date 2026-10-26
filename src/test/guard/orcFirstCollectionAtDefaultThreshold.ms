// nim-guard: the first cycle collection runs when the registered roots reach the default
// threshold of 128, because the roots threshold starts at zero.
//
// Reference: the threshold is a zero-initialised thread variable and registration collects when
// `roots.len - defaultThreshold >= rootsThreshold` (lib/system/orc.nim:382, :522, defaultThreshold
// :377), so the 128th root collects. A collection that frees nothing raises the threshold from
// zero to the default and then by half (:499-501), so the next one runs 320 registrations later.
// Proven red with the initial threshold 128 in runtime/drc.c: the first collection ran at 256 roots.
//
// RED MEANS the initial roots threshold drifted; run /trace-ref on msRootsThreshold against orc.nim.

@passC("-DMSGC_ORC_STATS");
@compile("./fixtures/orcCollections.c");

import { msTestOrcCollections } from "./fixtures/orcCollections.h";

class Node {
	next: Node | null = null;
}

class Slot {
	held: Node | null = null;
}

const firstCollectionRoots = 128;
const secondCollectionRoots = 320;
const nodeCount = 1000;

function main(): void {
	const nodes: Node[] = [];
	for (let i = 0; i < nodeCount; i++) {
		const node = new Node();
		node.next = node;
		nodes.push(node);
	}
	const slot = new Slot();
	const collectionsAt: int32[] = [];
	let seen = 0;
	for (let i = 0; i < nodeCount; i++) {
		slot.held = nodes[i];
		slot.held = null;
		if (msTestOrcCollections() > seen) {
			seen = msTestOrcCollections();
			collectionsAt.push(i + 1);
		}
	}
	if (collectionsAt.length < 2 || collectionsAt[0] != firstCollectionRoots || collectionsAt[1] - collectionsAt[0] != secondCollectionRoots) {
		throw new Error(`collections after ${collectionsAt.join(", ")} registered roots, expected ${firstCollectionRoots} then +${secondCollectionRoots}`);
	}
	console.log("first collection at 128 roots");
}
main();
