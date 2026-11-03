// @stdout: before collectCycles: holders 0 nodes 0 bags 0
// @stdout: after collectCycles: holders 3 of 3, nodes 20 of 20, bags 4 of 4
// @skip-js: onDestroy does not run on JS
// note: collectCycles frees every garbage cycle at once, below the collection threshold, and runs their onDestroy before the next line: a cycle through a closure's env, a two-node ring and a self-cycle through an array.

import { collectCycles } from "std/runtime";

class Holder { f: (() => int32) | null = null; id: int32 = 0; }
class Node { next: Node | null = null; }
class Bag { items: Bag[] = []; tag: int32 = 0; }

let holders: int32 = 0;
let nodes: int32 = 0;
let bags: int32 = 0;
function onDestroy(this h: Holder): void { holders += 1; }
function onDestroy(this n: Node): void { nodes += 1; }
function onDestroy(this b: Bag): void { bags += 1; }

function closureCycle(i: int32): void {
	const h = new Holder();
	h.id = i;
	h.f = (): int32 => h.id;
}

function nodeCycle(): void {
	const a = new Node();
	const b = new Node();
	a.next = b;
	b.next = a;
}

function bagCycle(): void {
	const b = new Bag();
	b.items.push(b);
	b.tag = 1;
}

for (let i: int32 = 0; i < 3; i++) closureCycle(i);
for (let i: int32 = 0; i < 10; i++) nodeCycle();
for (let i: int32 = 0; i < 4; i++) bagCycle();
console.log(`before collectCycles: holders ${holders} nodes ${nodes} bags ${bags}`);
collectCycles();
console.log(`after collectCycles: holders ${holders} of 3, nodes ${nodes} of 20, bags ${bags} of 4`);
