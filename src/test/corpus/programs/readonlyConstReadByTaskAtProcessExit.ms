// @stdout: main exits
// @stdout: task done 15000000
// @serial
// @ledger-slack(msStringArrayRefCell) 2
// @ledger-slack(Cell) 1
// @ledger-slack(Child) 1
// @ledger-slack(msRefArrayRefCell) 1
// @ledger-slack(msFuture) 1
// @skip-js: spawn on JS is a microtask that starts after main has left, and process.exit on node ends the process before it runs, so the task's line never prints there
// note: process.exit(0) while a task reads a deep Readonly module const with no rc op: the exit's pool shutdown lets the running task finish before the process tears down, so the const's cell, its child and its string stay valid for the task's whole read. The sibling where main returns instead is readonlyConstReadByTaskOutlivingMain.

import { exit } from "std/process";

class Child { n: int32 = 1; }
class Cell { child: Child = new Child(); name: string = "na" + "me"; }
const K: Readonly<Cell> = new Cell();
let handles: Promise<int32>[] = [];

function readLong(): int32 {
	let s = 0;
	for (let i = 0; i < 3000000; i += 1) s += K.child.n + K.name.length;
	console.log("task done", s);
	return s;
}

function main(): void {
	console.log("main exits");
	handles.push(spawn(() => readLong()));
	exit(0);
}

main();
