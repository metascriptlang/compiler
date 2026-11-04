// A narrowed `T | null` read whose payload is consumed (bound, assigned, stored into a
// field, passed by value) leaves the nullable owning its own payload, on every lane.
// @stdout: closure li li li
// @stdout: tree (1 (2 3)) -2 (1 3) -1 (2 3) -3 (1 2)
// @stdout: deep ((1 2) (3 4)) -3 ((1 2) 4)
// @stdout: wrap 7 8 9
// @stdout: passed 5 5

class Mock {
	tag: string;
	constructor(tag: string) { this.tag = tag; }
}

interface Host { cloneNode: ((node: unknown) => string) | null; }

function viaAlias(host: Host, node: unknown): string {
	const cloner = host.cloneNode;
	if (cloner === null) { return "none"; }
	const clone = cloner;
	return clone(node);
}

interface Pane { id: int32; }
interface Split { first: Node; second: Node; }
enum NodeKind { Pane, Split }
struct Node = match (kind: NodeKind) {
	NodeKind.Pane => { pane: Pane },
	NodeKind.Split => { split: Split },
};

function leaf(id: int32): Node { return { kind: NodeKind.Pane, pane: { id: id } }; }
function pair(a: Node, b: Node): Node { return { kind: NodeKind.Split, split: { first: a, second: b } }; }

function without(this n: Node, id: int32): Node | null {
	if (n.kind == NodeKind.Pane) { return n.pane.id == id ? null : n; }
	const first = n.split.first.without(id);
	if (first === null) { return n.split.second; }
	const second = n.split.second.without(id);
	if (second === null) { return n.split.first; }
	n.split.first = first;
	n.split.second = second;
	return n;
}

function show(n: Node): string {
	if (n.kind == NodeKind.Pane) { return "" + n.pane.id; }
	return "(" + show(n.split.first) + " " + show(n.split.second) + ")";
}

function dropShown(t: Node, id: int32): string {
	const r = t.without(id);
	return r === null ? "none" : show(r);
}

struct Point { x: int32; label: string; }
struct Wrap { point: Point; }

function maybePoint(x: int32): Point | null {
	return x < 0 ? null : { x: x, label: "p" + x };
}

function wrapped(x: int32): Wrap {
	let w: Wrap = { point: { x: 0, label: "zero" } };
	const p = maybePoint(x);
	if (p === null) { return w; }
	w.point = p;
	return w;
}

function idOf(n: Node): int32 { return n.kind == NodeKind.Pane ? n.pane.id : -1; }

function passed(o: Node | null): int32 {
	if (o === null) { return 0; }
	return idOf(o);
}

const host: Host = { cloneNode: (node: unknown): string => (node as unknown as Mock).tag };
const li: unknown = new Mock("li") as unknown;
let closures = "closure";
for (let i = 0; i < 3; i++) { closures = closures + " " + viaAlias(host, li); }
console.log(closures);

const tree = pair(leaf(1), pair(leaf(2), leaf(3)));
console.log("tree " + show(tree) + " -2 " + dropShown(pair(leaf(1), pair(leaf(2), leaf(3))), 2) + " -1 " + dropShown(pair(leaf(1), pair(leaf(2), leaf(3))), 1) + " -3 " + dropShown(pair(leaf(1), pair(leaf(2), leaf(3))), 3));

const deep = pair(pair(leaf(1), leaf(2)), pair(leaf(3), leaf(4)));
console.log("deep " + show(deep) + " -3 " + dropShown(pair(pair(leaf(1), leaf(2)), pair(leaf(3), leaf(4))), 3));

console.log("wrap " + wrapped(7).point.x + " " + wrapped(8).point.label.slice(1) + " " + wrapped(9).point.x);

const five: Node | null = leaf(5);
console.log("passed " + passed(five) + " " + passed(five));
