// @exit: 1
// @stdout: linked 2
// @stdout: Error: onDestroy kept a reference to the Leaf it destroys
// @xfail(san): the program stops inside the collection, so the cycle's other Leaf is never destroyed (ledger Leaf alloc=2 destroy=1)
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS; `extern function` binds a C symbol
// note: the collector's free path compares the count before and after the hook at full width too:
// the helper adds 2^32 - 1 references, so the one the hook keeps brings the count to 2^32, which a
// 32-bit read sees as 0. Siblings: onDestroyKeepingThisPastWordStops (the plain free path),
// onDestroyKeepingThisInCycleStops.

@include("./ffi.h");

import { collectCycles } from "std/runtime";

extern function corpusKeepNearWord(p: Ptr<void>): void;

const kept: Peer[] = [];

class Peer {
	other: Peer | null = null;
	onDestroy(): void {
		corpusKeepNearWord(this as Ptr<void>);
		kept.push(this);
	}
}

class Leaf extends Peer {}

function link(): void {
	const a = new Leaf();
	const b = new Leaf();
	a.other = b;
	b.other = a;
	console.log("linked 2");
}

link();
collectCycles();
