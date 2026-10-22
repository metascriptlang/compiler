// @stdout: started 2
// @stdout: left
// @stdout: finished 1
// @stdout: finished 2
// @exit: 0
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so a task spinning on the gate for another task's turn never yields to it
// note: an async routine keeps the handles of tasks that capture only copies in an array and a Map and returns without awaiting them; the tasks run on after the routine ended and the program waits for them before it ends, while the event loop exists. Each task waits for its turn on a gate the top level opens after printing `left`, so an exit join would wait forever (old compiler: no output, killed by the runner's timeout). The sync neighbour, where the program never awaits, is spawnIsolatedOutlivesItsScope.

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Gate { turn: int32; }

const gate = new Locked<Gate>({ turn: 0 });

function waitTurn(k: int32): void {
	while (lockedRead(gate, (g: Gate): int32 => { return g.turn; }) != k) {}
}

function passTurn(): void {
	lockedUpdate(gate, (g: Gate): Gate => { return { turn: g.turn + 1 }; });
}

function finish(k: int32): int32 {
	waitTurn(k);
	console.log(`finished ${k}`);
	passTurn();
	return k;
}

async function startAndLeave(): Promise<int32> {
	const kept: Promise<int32>[] = [];
	kept.push(spawn(() => finish(1)));
	const byKey = new Map<string, Promise<int32>>();
	byKey.set("b", spawn(() => finish(2)));
	return (kept.length + byKey.size) as int32;
}

console.log(`started ${await startAndLeave()}`);
console.log("left");
lockedUpdate(gate, (g: Gate): Gate => { return { turn: 1 }; });
