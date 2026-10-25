// @stdout: started 2
// @stdout: left
// @stdout: finished 1
// @stdout: Error: unhandled rejection: isolated task failed with nobody awaiting
// @exit: 1
// @serial
// @skip-raiser: the Raiser runs spawn inline
// @skip-js: JS runs every task on the one thread, so a task spinning on the gate for another task's turn never yields to it
// note: a task that captures only copies is an ordinary promise: the routine that spawned it stores its handle in a Map and leaves without joining it, the task runs on after the exit, and the program does not end before it finishes; the failure nobody awaited is reported at the end with exit 1. The tasks wait for their turn on a gate the top level opens after printing `left`, so a scope exit that joined them would wait forever (old compiler: no output, killed by the runner's timeout). The program never awaits, so it ends with no event loop: an exit that did not wait for the running tasks tore `gate` down under them (old exit drain: SEGV in the worker). The async neighbour, where the loop exists at exit, is spawnIsolatedOutlivesAsyncScope.

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Gate { turn: int32; }

const gate = new Locked<Gate>({ turn: 0 });

function finish(k: int32): int32 {
	while (lockedRead(gate, (g: Gate): int32 => { return g.turn; }) != k) {}
	if (k == 2) throw new Error("isolated task failed with nobody awaiting");
	console.log(`finished ${k}`);
	lockedUpdate(gate, (g: Gate): Gate => { return { turn: g.turn + 1 }; });
	return k;
}

function startAndLeave(): int32 {
	const byKey = new Map<int32, Promise<int32>>();
	byKey.set(2, spawn(() => finish(2)));
	byKey.set(1, spawn(() => finish(1)));
	return byKey.size as int32;
}

console.log(`started ${startAndLeave()}`);
console.log("left");
lockedUpdate(gate, (g: Gate): Gate => { return { turn: 1 }; });
