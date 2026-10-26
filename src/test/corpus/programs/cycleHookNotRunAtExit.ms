// @stdout: end
// note: a self-cycle still garbage at exit is never collected, so its onDestroy prints nothing on any backend; the author who needs it calls collectCycles (sibling collectCyclesRunsCycleHook). Async sibling: cycleHookNotRunAtExitAfterAwait.

class Node {
	name: string;
	next: Node | null = null;
	constructor(name: string) {
		this.name = name;
	}
	onDestroy(): void {
		console.log("destroy " + this.name);
	}
}

function link(): void {
	const a = new Node("self");
	a.next = a;
	console.log("linked");
}

link();
console.log("end");
