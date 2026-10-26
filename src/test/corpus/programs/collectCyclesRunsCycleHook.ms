// @stdout: destroy self
// @stdout: destroyed 1
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so collectCycles finds nothing to run and it prints destroyed 0
// @skip-js: onDestroy does not run on JS
// note: collectCycles collects a garbage self-cycle before exit and runs its onDestroy then, which exit alone never does (sibling cycleHookNotRunAtExit).

import { collectCycles } from "std/runtime";

let destroyed = 0;

class Node {
	name: string;
	next: Node | null = null;
	constructor(name: string) {
		this.name = name;
	}
	onDestroy(): void {
		destroyed = destroyed + 1;
		console.log("destroy " + this.name);
	}
}

function link(): void {
	const a = new Node("self");
	a.next = a;
	console.log("linked");
}

link();
collectCycles();
console.log("destroyed " + destroyed.toString());
