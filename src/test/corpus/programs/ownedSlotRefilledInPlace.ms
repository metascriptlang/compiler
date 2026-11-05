// note: an owned slot moved out and put back by the same assignment is rewritten in place: a Vec element, a field, a slot two holders deep and a field of a ref parameter; a nullable element is emptied by the move; a callee that throws before the refill leaves the moved slot holding its child, on C and JS alike.
// @stdout: bumped 1291 13
// @stdout: field 107 108
// @stdout: deep 1108
// @stdout: ref 207
// @stdout: nullable 3 null
// @stdout: thrown boom kept 1
class N {
	id: int32 = 0;
	kids: Vec<Owned<N>> = [];
	constructor(id: int32) { this.id = id; }
}

class Pair {
	head: Owned<N>;
	maybe: Vec<Owned<N> | null> = [];
	constructor(sink head: Owned<N>) { this.head = move head; }
}

function build(depth: int32, next: int32[]): Owned<N> {
	const n: Owned<N> = new N(next[0]);
	next[0] += 1;
	if (depth > 0) {
		for (let i = 0; i < 3; i += 1) n.kids.push(build(depth - 1, next));
	}
	return move n;
}

function bump(n: Owned<N>): Owned<N> {
	n.id = n.id + 100;
	for (let i = 0; i < n.kids.length; i += 1) n.kids[i] = bump(move n.kids[i]);
	return move n;
}

function boom(n: Owned<N>): Owned<N> {
	if (n.id > 0) throw new Error("boom");
	return move n;
}

function sum(n: N): int32 {
	let total = n.id;
	for (const k of n.kids) total += sum(k);
	return total;
}

function count(n: N): int32 {
	let total = 1;
	for (const k of n.kids) total += count(k);
	return total;
}

function bumpHead(ref p: Pair): void {
	p.head = bump(move p.head);
}

function run(): void {
	const next: int32[] = [1];
	const root: Owned<N> = build(2, next);
	for (let i = 0; i < root.kids.length; i += 1) root.kids[i] = bump(move root.kids[i]);
	console.log("bumped " + sum(root).toString() + " " + count(root).toString());

	let p = new Pair(new N(7));
	p.head.kids.push(new N(8));
	p.head = bump(move p.head);
	console.log("field " + p.head.id.toString() + " " + p.head.kids[0].id.toString());
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	p.head.kids[0] = bump(move p.head.kids[0]);
	console.log("deep " + p.head.kids[0].id.toString());
	bumpHead(p);
	console.log("ref " + p.head.id.toString());

	p.maybe.push(new N(3));
	const taken = move p.maybe[0];
	console.log("nullable " + (taken != null ? taken.id.toString() : "none") + " " + (p.maybe[0] == null ? "null" : "kept"));

	const holder: Owned<N> = new N(0);
	holder.kids.push(new N(1));
	try {
		holder.kids[0] = boom(move holder.kids[0]);
	} catch (e) {
		console.log("thrown " + (e as Error).message + " kept " + holder.kids[0].id.toString());
	}
}

run();
