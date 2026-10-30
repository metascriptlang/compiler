// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @stdout: fresh open 1
// @stdout: fresh beat 1
// @stdout: fresh beat 2
// @stdout: moved open 1
// @stdout: moved beat 1
// @stdout: moved beat 2
// @serial
// note: a cell that became a cycle root on the main thread reaches an actor through its constructor's sink parameter, once as a fresh value and once by `move`. The actor's private helper returns a graph that reaches the cell, and its result is disowned from the actor's root set. Before the fix the cell kept its root entry in main's set, so that disown stopped with "M1 owner violation".

class Cell {
	next: Cell | null = null;
}

struct Info {
	name: string;
	cell: Cell;
}

function touch(cell: Cell): void {
	cell.next = cell;
	cell.next = null;
}

function load(): Info {
	const cell = new Cell();
	touch(cell);
	return { name: "m", cell: cell };
}

class Worker {
	cell: Cell;
	n: int32 = 0;
	constructor(cell: Cell) { this.cell = cell; }
}

actor Caller {
	info: Info;
	worker: Worker | null = null;
	spare: Cell = new Cell();
	constructor(sink info: Info) { this.info = info; }
	open(): int32 {
		this.worker = new Worker(this.info.cell);
		return 1;
	}
	beat(): int32 {
		touch(this.spare);
		const w = this.opened();
		w.n += 1;
		return w.n;
	}
	private opened(): Worker {
		const w = this.worker;
		if (w === null) { throw new Error("not open"); }
		return w;
	}
}

async function drive(label: string, caller: Caller): Promise<void> {
	console.log(`${label} open ${await caller.open()}`);
	console.log(`${label} beat ${await caller.beat()}`);
	console.log(`${label} beat ${await caller.beat()}`);
}

async function main(): Promise<void> {
	await drive("fresh", new Caller(load()));
	const info = load();
	await drive("moved", new Caller(move info));
}

await main();
