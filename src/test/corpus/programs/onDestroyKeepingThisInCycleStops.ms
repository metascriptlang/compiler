// @exit: 1
// @stdout: linked 2
// @stdout: Error: onDestroy kept a reference to the Leaf it destroys
// @xfail(san): the program stops inside the collection, so the cycle's other Leaf is never destroyed (ledger Leaf alloc=2 destroy=1)
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS
// note: the collector frees a cycle whose inherited onDestroy stores `this` in a global; the program stops with the freed object's own class named. Sibling: onDestroyKeepingThisStops (the plain free path).

import { collectCycles } from "std/runtime";

const kept: Peer[] = [];

class Peer {
	other: Peer | null = null;
	onDestroy(): void {
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
