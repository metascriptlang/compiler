// @stdout: direct 1
// @stdout: wrapped 2
// @stdout: array 3
// @stdout: acyclic 3
// @stdout: posted 4
// @serial
// @ledger-slack(Worker) 1
// ledger-slack reason: its actor is never stopped, so it is still live at exit
// note: a cyclic graph moved into an actor call, awaited or not, leaves the caller's cycle roots, so the actor frees it over its own root set.

class Cell {
	items: int32[] = [];
	kids: Cell[] = [];
}

class Flat {
	items: int32[] = [1, 2, 3];
}

struct Request {
	name: string;
	args: Cell;
}

function build(): Cell {
	const c = new Cell();
	c.kids.push(new Cell());
	return c;
}

function buildAll(): Cell[] {
	const out: Cell[] = [];
	out.push(build());
	out.push(build());
	return out;
}

actor Worker {
	seen: int32 = 0;
	direct(cell: Cell): int32 {
		this.seen += cell.kids.length as int32;
		return this.seen;
	}
	wrapped(request: Request): int32 {
		this.seen += request.args.kids.length as int32;
		return this.seen;
	}
	array(cells: Cell[]): int32 {
		this.seen += cells.length as int32 - 1;
		return this.seen;
	}
	post(request: Request): void {
		this.seen += request.args.kids.length as int32;
	}
	count(): int32 {
		return this.seen;
	}
	acyclic(flat: Flat): int32 {
		return flat.items.length as int32;
	}
}

async function main(): Promise<void> {
	const worker = new Worker();
	const cell = build();
	console.log(`direct ${await worker.direct(move cell)}`);
	const request: Request = { name: "x", args: build() };
	console.log(`wrapped ${await worker.wrapped(move request)}`);
	const cells = buildAll();
	console.log(`array ${await worker.array(move cells)}`);
	const flat = new Flat();
	console.log(`acyclic ${await worker.acyclic(move flat)}`);
	const posted: Request = { name: "y", args: build() };
	worker.post(move posted);
	console.log(`posted ${await worker.count()}`);
}

await main();
