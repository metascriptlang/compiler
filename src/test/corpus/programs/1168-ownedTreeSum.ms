// note: Owned<N> is a type-level ownership edge: a tree built through Vec<Owned<N>>, a linked list through Owned<N> | null and a move out of a local give the same result on C and JS.
class N {
	id: int32 = 0;
	kids: Vec<Owned<N>> = [];
	next: Owned<N> | null = null;
	constructor(id: int32) { this.id = id; }
}

function build(depth: int32, next: int32[]): Owned<N> {
	const n: Owned<N> = new N(next[0]);
	next[0] += 1;
	if (depth > 0) {
		for (let i = 0; i < 3; i += 1) n.kids.push(build(depth - 1, next));
	}
	return n;
}

function sum(n: N): int32 {
	let total = n.id;
	for (let i = 0; i < n.kids.length; i += 1) total += sum(n.kids[i]);
	return total;
}

function chain(length: int32): Owned<N> {
	const head: Owned<N> = new N(0);
	let tail: N = head;
	for (let i = 1; i < length; i += 1) {
		const link: Owned<N> = new N(i);
		tail.next = link;
		tail = tail.next!;
	}
	return head;
}

function length(head: N): int32 {
	let count = 0;
	let at: N | null = head;
	while (at != null) {
		count += 1;
		at = at.next;
	}
	return count;
}

function adopt(parent: N): void {
	const child: Owned<N> = new N(100);
	parent.kids.push(child);
}

const root = build(3, [0]);
console.log("tree", sum(root));
const list = chain(5);
console.log("chain", length(list));
adopt(root);
console.log("adopted", sum(root), root.kids.length);
