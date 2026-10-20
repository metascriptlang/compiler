// @exit: 1
// @stdout: linked 2
// @stdout: Error: onDestroy kept a reference to the Leaf it destroys
// @xfail(c): --gc=drc has no cycle collector, so the cycle is never freed and its onDestroy never runs
// @xfail(danger): built with --gc=drc, which has no cycle collector, so the cycle is never freed
// @xfail(san): built with --gc=drc, which has no cycle collector, so the cycle is never freed
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the program exits 0
// @skip-js: onDestroy does not run on JS
// note: the collector frees a cycle whose inherited onDestroy stores `this` in a global; the program stops with the freed object's own class named. Sibling: onDestroyKeepingThisStops (the plain free path).

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
