// @stdout: main done
// @stdout: task done 15000000
// @serial
// note: a task that reads a deep Readonly module const with no rc op is still running when main returns; the program waits for it before it ends, so the const's cell, its child and its string stay valid for the task's whole read and are destroyed once, after it. The sibling that ends with process.exit is readonlyConstReadByTaskAtProcessExit.

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
	console.log("main done");
	handles.push(spawn(() => readLong()));
}

main();
