// @stdout: true 2 1 2
// @stdout: true 2 1 2
// @stdout: done
// @stdout: true 1 0 2 true
// @stdout: true 1 0 2 true
// @stdout: true 2 7 3
// @stdout: true 2 7 3
// note: a deep-Readonly module const is marked immortal after its initializer; storing it, a child of it and a list of it into holders (one of them self-cyclic) counts them through the Ro flavor, and the exit phase frees the graph once after every module deinit, so the SAN ledger stays balanced; an Unowned<Readonly<T>> edge to it is counted through the Ro flavor of the Unowned ops (assign, take, give, holder and array release); a Readonly<S> value, a struct const or one reached from a const, copies through its own hook pair whose fields count through the Ro flavor.
class Leaf { n: int32 = 1; }
class Node { next: Node | null = null; leaf: Leaf = new Leaf(); leaves: Leaf[] = [new Leaf(), new Leaf()]; tag: string = "t"; }
function chain(): Node {
	const a = new Node();
	const b = new Node();
	b.next = new Node();
	a.next = b;
	return a;
}
const EMPTY: Readonly<Node> = chain();
class Holder { head: Readonly<Node> | null = null; leaf: Readonly<Leaf> | null = null; list: Readonly<Node>[] = []; }
class Cyc { self: Cyc | null = null; head: Readonly<Node> | null = null; }
function run(): void {
	const h = new Holder();
	h.head = EMPTY;
	h.leaf = EMPTY.leaf;
	h.list.push(EMPTY);
	const n2 = EMPTY.next;
	if (n2 != null) h.list.push(n2);
	const c = new Cyc();
	c.self = c;
	c.head = EMPTY;
	console.log(h.head === EMPTY, h.list.length, h.leaf!.n, EMPTY.leaves.length);
}
run();
run();
console.log("done");

class UH { up: Unowned<Readonly<Node>> | null = null; ups: Vec<Unowned<Readonly<Node>>> = []; arr: Unowned<Readonly<Node>>[] = []; }
struct US { up: Unowned<Readonly<Node>>; ups: Unowned<Readonly<Node>>[]; }
function runUnowned(): void {
	const h = new UH();
	h.up = EMPTY;
	h.up = EMPTY;
	h.ups.push(EMPTY);
	h.arr.push(EMPTY);
	h.arr.push(EMPTY);
	h.arr.splice(0, 1);
	const s: US = { up: EMPTY, ups: [EMPTY, EMPTY] };
	const s2 = s;
	const p = h.arr.pop();
	console.log(h.up === EMPTY, h.ups.length, h.arr.length, s2.ups.length, p === EMPTY);
}
runUnowned();
runUnowned();

struct W { leaf: Leaf; tag: int32; }
class WNode { w: W = { leaf: new Leaf(), tag: 7 }; }
const KW: Readonly<W> = { leaf: new Leaf(), tag: 3 };
const WROOT: Readonly<WNode> = new WNode();
class WH { w: Readonly<W> | null = null; ws: Readonly<W>[] = []; }
function runStruct(): void {
	const h = new WH();
	const local: Readonly<W> = WROOT.w;
	h.w = local;
	h.ws.push(KW);
	h.ws.push(WROOT.w);
	console.log(h.ws[1].leaf === WROOT.w.leaf, h.ws.length, local.tag, h.ws[0].tag);
}
runStruct();
runStruct();
