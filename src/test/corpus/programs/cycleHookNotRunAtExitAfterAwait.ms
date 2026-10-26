// @stdout: got 1
// note: the program starts the spawn pool, so exit runs its shutdown; a self-cycle made in the spawned task (a worker's roots) and one made after the await are both still garbage at exit and neither onDestroy prints, on any backend. Siblings: cycleHookNotRunAtExit, collectCyclesRunsCycleHookAfterAwait.

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

function selfCycle(name: string): int32 {
	const n = new Node(name);
	n.next = n;
	return 1;
}

async function work(): Promise<int32> {
	const v = await spawn(() => selfCycle("in-spawn"));
	selfCycle("after-await");
	return v;
}

async function main(): Promise<void> {
	const v = await work();
	console.log("got " + v.toString());
}

main();
