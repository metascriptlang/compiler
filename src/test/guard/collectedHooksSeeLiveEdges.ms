// guard: every onDestroy of a collected cycle runs once, before any cell of the cycle is released
//
// INVARIANT (two-phase finalization, a divergence from the reference collectColor, which nils each
//   slot before the destructors run because its refs are nilable): a non-null field read in
//   onDestroy holds its peer, the peer's own fields still hold, and a slot the hook writes is
//   released like any field.
//
// WHAT IT CATCHES: a slot nilled before the hooks run (null member access on `n.peer.name`), a
//   hook run twice (counts off), a peer released before another cell's hook reads it, a value a
//   hook stores into a dead cell's slot leaked or freed twice, a base onDestroy skipped.
//
// AXES: cycle of 1, 2 and 3 cells; a hook calling a method on its peer and reading two hops away;
//   a hook writing a fresh value into its slot; a base hook under a derived hook and under a class
//   without one.
//
// RED MEANS: the collector's finalize or release phase drifted. Run /trace-ref on
//   finalizeCollected (runtime/drc.c) and generateFinalize (destructorLifting.ms).
// GUARD-BALANCE Node
// GUARD-BALANCE Leaf
// GUARD-BALANCE Mid
import { collectCycles } from "std/runtime";

class Node {
	peer: Node;
	name: string;
	constructor(name: string) { this.name = name; this.peer = this; }
	greet(): string { return "hi " + this.name; }
}
function onDestroy(this n: Node): void {
	if (n.name == "fresh") return;
	hooks += 1;
	seen = seen + n.name + n.peer.greet() + n.peer.peer.name + ";";
	if (n.name == "x") n.peer = new Node("fresh");
}

class Base { other: Base | null = null; name: string = ""; }
function onDestroy(this b: Base): void { order = order + "base " + b.name + (b.other != null ? (b.other as Base).name : "?") + ";"; }
class Mid extends Base { more: string = "m"; }
class Leaf extends Mid { tag: string = "t"; }
function onDestroy(this l: Leaf): void { order = order + "leaf " + l.name + ";"; }

let hooks: int32 = 0;
let seen = "";
let order = "";

function ring(names: string[]): void {
	const nodes: Node[] = [];
	for (const name of names) nodes.push(new Node(name));
	for (let i = 0; i < nodes.length; i += 1) nodes[i].peer = nodes[(i + 1) % nodes.length];
}

function pair(): void {
	const a = new Leaf();
	a.name = "a";
	const b = new Mid();
	b.name = "b";
	a.other = b;
	b.other = a;
}

ring(["x"]);
ring(["a", "b"]);
ring(["p", "q", "r"]);
collectCycles();
if (hooks != 6) throw new Error(`hooks ran ${hooks} times, want 6`);
for (const part of ["xhi xx;", "ahi ba;", "bhi ab;", "phi qr;", "qhi rp;", "rhi pq;"]) {
	if (!seen.includes(part)) throw new Error(`a hook saw '${seen}', missing '${part}'`);
}
pair();
collectCycles();
if (order != "base ba;leaf a;base ab;" && order != "leaf a;base ab;base ba;") throw new Error(`hook order '${order}'`);
console.log("GUARD-OK");
