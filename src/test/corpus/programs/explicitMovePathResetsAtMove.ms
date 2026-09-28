// @stdout: self field 2 | self element 2 | decl 2/1 | assign 2/1 | return 2/1 | two 2/2 | loop 6 | order 33 | refill 3/7 | advance 2 | advance returned 2 | walk 123 | leaf refill 3/24 | leaf early caught/0 | leaf late 3/1 | leaf loop 6 | leaf self 3
// note: an explicit move of a field path takes the value and empties the source at the move, on the location it evaluated once; nothing resets the path again at scope exit, so a later write, index step or throw leaves the source and its payload intact.

struct Node { kids: Vec<int32>; }
struct Tree { nodes: Vec<Node>; kids: Vec<int32>; }
struct Forest { trees: Vec<Tree>; }
struct Pair { n: int32; kids: Vec<int32>; }
class Box { kids: Vec<int32> = []; }
class Link {
	v: int32;
	next: Link | null = null;
	constructor(v: int32) { this.v = v; }
}
class Leaf {
	v: int32;
	constructor(v: int32) { this.v = v; }
}
class LeafBox { leaves: Vec<Leaf> = []; }
struct LeafNode { leaves: Vec<Leaf>; }
struct LeafTree { nodes: Vec<LeafNode>; }

let picks: int32 = 0;

function pick(): int32 {
	picks = picks + 1;
	return 0;
}

function mkTree(): Tree {
	return { nodes: [{ kids: [1, 2] }], kids: [3, 4] };
}

function mkForest(): Forest {
	return { trees: [mkTree()] };
}

function mkChain(): Link {
	const head = new Link(1);
	const middle = new Link(2);
	middle.next = new Link(3);
	head.next = middle;
	return head;
}

function linkCount(head: Link | null): int32 {
	let n: int32 = 0;
	let cur = head;
	while (cur != null) {
		n = n + 1;
		cur = cur.next;
	}
	return n;
}

function mkLeafTree(): LeafTree {
	return { nodes: [{ leaves: [new Leaf(1), new Leaf(2)] }, { leaves: [new Leaf(3)] }] };
}

function leafSum(leaves: Vec<Leaf>): int32 {
	let sum: int32 = 0;
	for (let i = 0; i < leaves.length; i++) sum = sum + leaves[i].v;
	return sum;
}

function selfField(): int32 {
	let t = mkTree();
	t.kids = move t.kids;
	return t.kids.length;
}

function selfElement(): int32 {
	let t = mkTree();
	t.nodes[0].kids = move t.nodes[0].kids;
	return t.nodes[0].kids.length;
}

function decl(): int32 {
	let t = mkTree();
	const kids = move t.nodes[pick()].kids;
	return kids.length;
}

function assign(): int32 {
	let t = mkTree();
	let kids: Vec<int32> = [9];
	kids = move t.nodes[pick()].kids;
	return kids.length;
}

function returned(): Vec<int32> {
	let t = mkTree();
	return move t.nodes[pick()].kids;
}

function two(): int32 {
	let f = mkForest();
	const kids = move f.trees[pick()].nodes[pick()].kids;
	return kids.length;
}

function loop(): int32 {
	let t: Tree = { nodes: [{ kids: [1, 2] }, { kids: [3] }, { kids: [4, 5, 6] }], kids: [] };
	let total: int32 = 0;
	for (let i = 0; i < t.nodes.length; i++) {
		const kids = move t.nodes[i].kids;
		total = total + kids.length;
	}
	return total;
}

function order(): int32 {
	let t = mkTree();
	t.kids.push(5);
	const p: Pair = { n: t.kids.length, kids: move t.kids };
	return p.n * 10 + p.kids.length;
}

function refill(box: Box): void {
	const taken = move box.kids;
	box.kids = [7, 8, 9];
}

function advance(): int32 {
	let cur: Link | null = mkChain();
	if (cur != null) cur = move cur.next;
	return linkCount(cur);
}

function advanceReturned(): Link | null {
	let cur: Link | null = mkChain();
	if (cur != null) {
		cur = move cur.next;
		return cur;
	}
	return null;
}

function walk(): int32 {
	let cur: Link | null = mkChain();
	let seen: int32 = 0;
	while (cur != null) {
		seen = seen * 10 + cur.v;
		cur = move cur.next;
	}
	return seen;
}

function leafRefill(box: LeafBox): void {
	const taken = move box.leaves;
	box.leaves = [new Leaf(7), new Leaf(8), new Leaf(9)];
}

function leafTaken(fail: boolean): int32 {
	let tree = mkLeafTree();
	if (fail) throw new Error("before the move");
	const taken = move tree.nodes[pick()].leaves;
	return leafSum(taken);
}

function leafLoop(): int32 {
	let tree = mkLeafTree();
	let total: int32 = 0;
	for (let i = 0; i < tree.nodes.length; i++) {
		const taken = move tree.nodes[i].leaves;
		total = total + leafSum(taken);
	}
	return total;
}

function leafSelf(): int32 {
	let tree = mkLeafTree();
	tree.nodes[0].leaves = move tree.nodes[0].leaves;
	return leafSum(tree.nodes[0].leaves);
}

function counted(label: string, value: int32): string {
	const line = `${label} ${value}/${picks}`;
	picks = 0;
	return line;
}

function main(): void {
	const parts: string[] = [];
	parts.push(`self field ${selfField()}`);
	parts.push(`self element ${selfElement()}`);
	parts.push(counted("decl", decl()));
	parts.push(counted("assign", assign()));
	parts.push(counted("return", returned().length));
	parts.push(counted("two", two()));
	parts.push(`loop ${loop()}`);
	parts.push(`order ${order()}`);
	const box = new Box();
	box.kids = [1, 2];
	refill(box);
	parts.push(`refill ${box.kids.length}/${box.kids[0]}`);
	parts.push(`advance ${advance()}`);
	parts.push(`advance returned ${linkCount(advanceReturned())}`);
	parts.push(`walk ${walk()}`);
	const leafBox = new LeafBox();
	leafBox.leaves = [new Leaf(1), new Leaf(2)];
	leafRefill(leafBox);
	parts.push(`leaf refill ${leafBox.leaves.length}/${leafSum(leafBox.leaves)}`);
	let early = "none";
	try {
		leafTaken(true);
	} catch (e) {
		early = "caught";
	}
	parts.push(`leaf early ${early}/${picks}`);
	picks = 0;
	parts.push(counted("leaf late", leafTaken(false)));
	parts.push(`leaf loop ${leafLoop()}`);
	parts.push(`leaf self ${leafSelf()}`);
	console.log(parts.join(" | "));
}

main();
