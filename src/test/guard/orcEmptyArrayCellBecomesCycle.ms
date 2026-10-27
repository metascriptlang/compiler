// nim-guard: an array that is empty at one collection and forms a cycle at the next is still
// collected, so skipping an empty cell in the trace leaves no leak.
//
// Reference: a collected cycle is found from its registered roots by markGray/scan/collectColor
// over the slots the trace pushes (lib/system/orc.nim collectCyclesBacon); an empty seq has no
// slot, so it cannot hide a cycle that does not exist yet. C only: JS has no collector.
//
// RED MEANS a cell skipped while empty kept a wrong count or colour into the next collection;
// check msOrcTraceRef in runtime/drc.h against the phases in runtime/drc.c.
//
// GUARD-BALANCE Node

@compile("./fixtures/orcArrayCellTrace.c");

import { msTestCollectNow } from "./fixtures/orcArrayCellTrace.h";

class Node {
	kids: Node[] = [];
	tag: int32 = 0;
}

const parked: Node[] = [];

function round(i: int32): int32 {
	const a = new Node();
	const b = new Node();
	a.tag = i;
	parked.push(a);
	parked.pop();
	msTestCollectNow();
	a.kids.push(b);
	b.kids.push(a);
	return a.kids.length as int32;
}

function main(): void {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 200; i++) {
		total = total + round(i);
		msTestCollectNow();
	}
	console.log(total);
	console.log("GUARD-OK");
}
main();
