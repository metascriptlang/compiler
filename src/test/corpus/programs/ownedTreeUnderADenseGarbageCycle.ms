// @skip-js: C-only by design: onDestroy counts the frees the collector makes; JS has no destructors
// @stdout: made 2 4 gone 2 4
// note: a garbage cycle whose cells hold more edges among themselves than the set has cells, with an owned tree hanging off it, is collected in a debug build: the owned-cycle check reads every edge of the set and finds no owned cycle.
import { collectCycles } from "std/runtime";

let madeP = 0;
let goneP = 0;
let madeN = 0;
let goneN = 0;

class N {
	kids: Owned<N>[] = [];
	constructor() { madeN += 1; }
	onDestroy(): void { goneN += 1; }
}

class P {
	a: P | null = null;
	b: P | null = null;
	c: P | null = null;
	d: P | null = null;
	tree: N | null = null;
	constructor() { madeP += 1; }
	onDestroy(): void { goneP += 1; }
}

function tree(): N {
	const root = new N();
	for (let i = 0; i < 3; i += 1) root.kids.push(new N());
	return root;
}

function dense(): void {
	const x = new P();
	const y = new P();
	x.a = y; x.b = y; x.c = y; x.d = y;
	y.a = x; y.b = x; y.c = x; y.d = x;
	x.tree = tree();
}

dense();
collectCycles();
console.log("made", madeP, madeN, "gone", goneP, goneN);
