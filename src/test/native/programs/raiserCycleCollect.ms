// Raiser ORC cycle collector (src/raiser/orc.ms) running AS COMPILED C. ARC alone
// cannot reclaim a reference cycle (a.next=b, b.next=a → each rc=1, reachable only
// via the other); the Bacon trial-deletion collector must. This is the only
// tier that runs it through the C backend.
// Builds a garbage cycle each round and collects it (heap free-list must recycle →
// bounded), while a keeper cycle held by an external ref must SURVIVE every round
// (guards over-collection → UAF). If the collector regressed: garbage cycles leak
// (objHeap grows unbounded → RSS balloons) or the keeper gets freed (keeperOk=0).

import { createArrayHeap, createStructHeap, heapAllocObject, heapObjectSetField, heapObjectFieldCount, raiserObject, rcIncref } from "../../../raiser/value";
import { orcCollectCycles } from "../../../raiser/orc";
import { console } from "std/core/system";

function main(): void {
	const arr = createArrayHeap();
	const obj = createStructHeap();

	const ka = heapAllocObject(obj);
	const kb = heapAllocObject(obj);
	rcIncref(arr, obj, raiserObject(kb)); heapObjectSetField(obj, ka, "next", raiserObject(kb));
	rcIncref(arr, obj, raiserObject(ka)); heapObjectSetField(obj, kb, "next", raiserObject(ka));
	rcIncref(arr, obj, raiserObject(ka));

	let totalFreed = 0;
	let round = 0;
	while (round < 100000) {
		const a = heapAllocObject(obj);
		const b = heapAllocObject(obj);
		rcIncref(arr, obj, raiserObject(b)); heapObjectSetField(obj, a, "next", raiserObject(b));
		rcIncref(arr, obj, raiserObject(a)); heapObjectSetField(obj, b, "next", raiserObject(a));
		totalFreed = totalFreed + orcCollectCycles(arr, obj);
		round = round + 1;
	}

	const keeperOk = obj.objects[ka].rc >= 1 && heapObjectFieldCount(obj, ka) === 1;
	console.log("raiser-cycle freed=" + (totalFreed % 1000000).toString() + " keeperOk=" + (keeperOk ? "1" : "0"));
}

main();
