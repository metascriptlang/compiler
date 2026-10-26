// @xfail(raiser): raiser runtime error: expected an object, got value kind Array
// @maxrss: 30
// @stdout: raiser-cycle freed=200000 keeperOk=1
// note: Raiser ORC cycle collector (src/raiser/orc.ms, Bacon buffered roots) running AS COMPILED C — the only tier that does. ARC (plain refcount) cannot reclaim a reference cycle (a.next=b, b.next=a → each rc=1, reachable only via the other); the collector must. Builds + collects a garbage cycle each of 100k rounds (free-list must recycle → objHeap bounded, RSS flat); a keeper cycle held by an external ref is registered every round and must SURVIVE each collection (guards over-collection → UAF). freed=200000 proves every garbage cycle was reclaimed (2/round); flat RSS proves the freed slots recycle (not just counted); keeperOk=1 proves the externally-reachable cycle was kept + its rc restored each scan. If the collector regresses to a no-op the garbage leaks (objHeap grows unbounded → RSS balloons → over bound); if it over-collects the keeper, keeperOk=0.

import { createArrayHeap, createStructHeap, heapAllocObject, heapObjectSetField, heapObjectFieldCount, raiserObject, rcIncref, rcDecrefHandle, handleIndex, createClassType, layOutObject } from "../../../raiser/value";
import { RaiserRegClass } from "../../../raiser/bytecode";
import { orcRegisterCandidate, orcCollect } from "../../../raiser/orc";
import { console } from "std/core/system";

function main(): void {
	const arr = createArrayHeap();
	const obj = createStructHeap();
	const nodeClass = createClassType("Node", -1, [], ["next"], [RaiserRegClass.Dyn]);
	nodeClass.cyclic[0] = true;
	const node = (): int64 => {
		const h = heapAllocObject(obj);
		layOutObject(obj.objects[handleIndex(h)], nodeClass);
		obj.objects[handleIndex(h)].rc = 0;
		return h;
	};
	const free = (h: int64): void => { rcDecrefHandle(arr, obj, h); };

	const ka = node();
	const kb = node();
	rcIncref(arr, obj, raiserObject(kb)); heapObjectSetField(obj, ka, "next", raiserObject(kb));
	rcIncref(arr, obj, raiserObject(ka)); heapObjectSetField(obj, kb, "next", raiserObject(ka));
	rcIncref(arr, obj, raiserObject(ka));

	let totalFreed = 0;
	let round = 0;
	while (round < 100000) {
		const a = node();
		const b = node();
		rcIncref(arr, obj, raiserObject(b)); heapObjectSetField(obj, a, "next", raiserObject(b));
		rcIncref(arr, obj, raiserObject(a)); heapObjectSetField(obj, b, "next", raiserObject(a));
		orcRegisterCandidate(arr, obj, a);
		orcRegisterCandidate(arr, obj, ka);
		totalFreed = (totalFreed + orcCollect(arr, obj, free)) as int32;
		round = round + 1;
	}

	const keeperOk = obj.objects[handleIndex(ka)].rc >= 1 && heapObjectFieldCount(obj, ka) == 1;
	console.log("raiser-cycle freed=" + (totalFreed % 1000000).toString() + " keeperOk=" + (keeperOk ? "1" : "0"));
}

main();
