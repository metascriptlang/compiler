// @stdout: destroy after-await
// @stdout: got 1 destroyed 1
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so collectCycles finds nothing to run and it prints destroyed 0
// @skip-js: onDestroy does not run on JS
// note: collectCycles after an await of a spawned task collects the self-cycle the continuation made and runs its onDestroy before the next line (sibling cycleHookNotRunAtExitAfterAwait).

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

function selfCycle(name: string): int32 {
	const n = new Node(name);
	n.next = n;
	return 1;
}

async function work(): Promise<int32> {
	const v = await spawn(() => 1);
	selfCycle("after-await");
	return v;
}

async function main(): Promise<void> {
	const v = await work();
	collectCycles();
	console.log("got " + v.toString() + " destroyed " + destroyed.toString());
}

main();
