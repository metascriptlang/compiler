// nim-guard: a ref array releases its elements with the element's own family
//
// INVARIANT: a sequence applies its element's destroy, so an element whose
//   type cannot form a cycle is released by plain RC, and only an element that
//   can form one goes through the cycle collector (liftdestructors seq ops,
//   trace gated by canFormAcycle). Every release surface of a ref array is
//   exercised for both families: scope exit, copy, sink, `length =`,
//   setLength, splice with an inserted item, and a captured array.
//
// WHAT IT PROTECTS: the ledger balance of both families here; the family each
//   array picks is pinned by run.ms refArrayAcyclicEmitsPlainRelease on the
//   emitted C of this same file.
//
// RED MEANS an array op released an element with the wrong family — run
//   /trace-nim on classifyArray and nativeLower's evictHelperName.
// GUARD-BALANCE TOTAL
// GUARD-JS

class Leaf {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}

class Link {
	tag: int32;
	next: Link | null = null;
	constructor(tag: int32) { this.tag = tag; }
}

function leafSum(arr: Leaf[]): int32 {
	let s: int32 = 0;
	for (const x of arr) s += x.tag;
	return s;
}

function linkSum(arr: Link[]): int32 {
	let s: int32 = 0;
	for (const x of arr) s += x.tag;
	return s;
}

function leafOps(): int32 {
	const a: Leaf[] = [new Leaf(1), new Leaf(2), new Leaf(3)];
	let b: Leaf[] = a;
	b = [new Leaf(4), new Leaf(5)];
	a.splice(1, 1, new Leaf(6));
	a.shrink(2);
	b.length = 0;
	const opt: (Leaf | null)[] = [new Leaf(10), null, new Leaf(11)];
	opt.length = 1;
	let held: Leaf[] = [new Leaf(7)];
	const grow = (): void => { held = [new Leaf(8), new Leaf(9)]; };
	grow();
	const kept = opt[0];
	return leafSum(a) + leafSum(b) + leafSum(held) + (kept != null ? kept.tag : 0);
}

function linkOps(): int32 {
	const a: Link[] = [new Link(1), new Link(2), new Link(3)];
	a[0].next = a[1];
	a[1].next = a[0];
	let b: Link[] = a;
	b = [new Link(4), new Link(5)];
	a.splice(1, 1, new Link(6));
	a.shrink(2);
	b.length = 0;
	const opt: (Link | null)[] = [new Link(10), null, new Link(11)];
	opt.length = 1;
	let held: Link[] = [new Link(7)];
	const grow = (): void => { held = [new Link(8), new Link(9)]; };
	grow();
	const kept = opt[0];
	return linkSum(a) + linkSum(b) + linkSum(held) + (kept != null ? kept.tag : 0);
}

function main(): int32 {
	let leaves: int32 = 0;
	let links: int32 = 0;
	for (let i = 0; i < 1000; i++) {
		leaves = leafOps();
		links = linkOps();
	}
	console.log(`leaves=${leaves} links=${links}`);
	if (leaves != 34 || links != 34) return 1;
	console.log("GUARD-OK");
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
