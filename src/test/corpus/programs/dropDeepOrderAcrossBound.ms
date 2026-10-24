// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): raiser runtime error: expected an object, got value kind Array (the Ptr<Meta> taken of a class field), on the base compiler as well
// @stdout: chain 50 ok 250 hooks
// @stdout: chain 200000 ok 1000000 hooks
// @stdout: tree 20 ok 61 hooks
// @stdout: tree 100000 ok 300001 hooks
// @stdout: deep-left 50 ok 300 hooks
// @stdout: deep-left 200000 ok 1200000 hooks
// @stdout: deep-right 50 ok 300 hooks
// @stdout: deep-right 200000 ok 1200000 hooks
// @stdout: caught 50 thrown 17
// @stdout: caught 200000 thrown 66667
// note: a deep drop that crosses the stack bound runs every onDestroy in the order the shallow drop runs them: each node's later fields, then its whole next subtree, then its earlier fields, and a hook that reads its node's memory through a Ptr reads it live; the expected order is computed before the drop
const log: number[] = [];
let thrown = 0;

struct Meta { v: number; }
struct Tag { id: number; meta: Ptr<Meta> | null; }
function onDestroy(this t: Tag): void {
	log.push(t.meta != null ? t.id + t.meta[].v : t.id);
}

struct Risky { id: number; }
function check(id: number): void {
	if (id % 3 == 0) throw new Error(`risky ${id}`);
}
function onDestroy(this r: Risky): void {
	try { check(r.id); } catch (e) { thrown += 1; }
	log.push(r.id);
}

class Leaf {
	id: number;
	constructor(id: number) { this.id = id; }
}
function onDestroy(this l: Leaf): void { log.push(l.id); }

class Link {
	a: Tag;
	meta: Meta;
	next: Link | null = null;
	leaf: Leaf;
	tags: Tag[] = [];
	b: Tag;
	constructor(i: number) {
		const k = i * 10;
		this.meta = { v: k + 5 };
		this.a = { id: 0, meta: null };
		this.leaf = new Leaf(k + 2);
		this.tags.push({ id: k + 3, meta: null });
		this.tags.push({ id: k + 4, meta: null });
		this.b = { id: k + 1, meta: null };
	}
}

class Tree {
	tag: Tag;
	kids: Tree[] = [];
	constructor(id: number) { this.tag = { id: id, meta: null }; }
}

class Bin {
	a: Tag;
	l: Bin | null = null;
	m: Tag;
	r: Bin | null = null;
	z: Tag;
	constructor(k: number) {
		this.a = { id: k + 3, meta: null };
		this.m = { id: k + 2, meta: null };
		this.z = { id: k + 1, meta: null };
	}
}

class Hot {
	r: Risky;
	next: Hot | null = null;
	constructor(i: number) { this.r = { id: i }; }
}

function verdict(name: string, n: number, want: number[]): void {
	let bad: number = 0;
	if (log.length != want.length) bad += 1;
	for (let i = 0; i < want.length && i < log.length; i++) if (log[i] != want[i]) bad += 1;
	console.log(`${name} ${n} ${bad == 0 ? "ok" : "BAD " + bad.toString()} ${log.length} hooks`);
	log.length = 0;
}

function chainCase(n: number): void {
	const want: number[] = [];
	for (let i = n - 1; i >= 0; i--) {
		want.push(i * 10 + 1);
		want.push(i * 10 + 3);
		want.push(i * 10 + 4);
		want.push(i * 10 + 2);
	}
	for (let i = 0; i < n; i++) want.push(i * 10 + 5);
	let h: Link | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Link(i);
		x.a.meta = x.meta as Ptr<Meta>;
		x.next = h;
		h = x;
	}
	log.length = 0;
	h = null;
	verdict("chain", n, want);
}

function tree(depth: number): Tree {
	const root = new Tree(depth * 3);
	let at = root;
	for (let d = depth; d >= 1; d--) {
		at.kids.push(new Tree(d * 3 + 1));
		at.kids.push(new Tree(d * 3 + 2));
		const deep = new Tree(d == 1 ? depth * 3 + 3 : (d - 1) * 3);
		at.kids.push(deep);
		at = deep;
	}
	return root;
}

function treeCase(depth: number): void {
	const want: number[] = [];
	for (let d = depth; d >= 1; d--) {
		want.push(d * 3 + 1);
		want.push(d * 3 + 2);
	}
	want.push(depth * 3 + 3);
	for (let d = 1; d <= depth; d++) want.push(d * 3);
	let root: Tree | null = tree(depth);
	log.length = 0;
	root = null;
	verdict("tree", depth, want);
}

function binCase(name: string, n: number, deepLeft: boolean): void {
	const want: number[] = [];
	for (let i = n - 1; i >= 0; i--) {
		want.push(i * 10 + 1);
		if (deepLeft) {
			want.push(i * 10 + 4);
			want.push(i * 10 + 5);
			want.push(i * 10 + 6);
			want.push(i * 10 + 2);
		}
	}
	for (let i = 0; i < n; i++) {
		if (!deepLeft) {
			want.push(i * 10 + 2);
			want.push(i * 10 + 4);
			want.push(i * 10 + 5);
			want.push(i * 10 + 6);
		}
		want.push(i * 10 + 3);
	}
	let h: Bin | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Bin(i * 10);
		const leaf = new Bin(i * 10 + 3);
		if (deepLeft) {
			x.l = h;
			x.r = leaf;
		} else {
			x.r = h;
			x.l = leaf;
		}
		h = x;
	}
	log.length = 0;
	h = null;
	verdict(name, n, want);
}

function throwCase(n: number): void {
	let h: Hot | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Hot(i);
		x.next = h;
		h = x;
	}
	log.length = 0;
	thrown = 0;
	h = null;
	let bad: number = 0;
	for (let i = 0; i < log.length; i++) if (log[i] != i) bad += 1;
	console.log(`caught ${bad == 0 && log.length == n ? n.toString() : "BAD"} thrown ${thrown}`);
	log.length = 0;
	thrown = 0;
}

chainCase(50);
chainCase(200000);
treeCase(20);
treeCase(100000);
binCase("deep-left", 50, true);
binCase("deep-left", 200000, true);
binCase("deep-right", 50, false);
binCase("deep-right", 200000, false);
throwCase(50);
throwCase(200000);
