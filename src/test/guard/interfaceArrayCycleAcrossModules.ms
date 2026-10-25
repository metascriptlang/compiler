// guard: a cycle that leaves its holder through an array of an interface declared in another module is collected
//
// INVARIANT (reference types.nim canFormAcycleAux, the non-final rule): a slot typed by an interface
//   takes every type the checker accepted behind it, wherever that type is declared, so a holder whose
//   array of that interface holds an implementer pointing back at it can form a cycle and is collected.
//   Axes: the interface and the holder in one module, the implementer in another; the edge out of the
//   holder runs through an array element.
//
// RED MEANS: the types held beyond the interface were recorded under a per-module copy of it, so the
//   holder was classified acyclic and every pair leaks (ListHolder and LinkNode alloc > destroy).
//   Run /trace-ref on noteHeldBeyond and canFormAcycle.
// GUARD-BALANCE ListHolder
// GUARD-BALANCE LinkNode

import { Named, ListHolder } from "./fixtures/heldBeyondHolder";

class LinkNode implements Named {
	name: string = "node";
	h: ListHolder | null = null;
}

function build(): int32 {
	const n = new LinkNode();
	const h = new ListHolder();
	h.es.push(n);
	n.h = h;
	return h.es.length as int32;
}

let total: int32 = 0;
for (let i: int32 = 0; i < 1000; i += 1) total += build();
console.log("done", total);
