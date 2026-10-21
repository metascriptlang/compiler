// @stdout: chain 10000 sum 49995000
// @stdout: leaf 3
// An @acyclic class is released by its reference count alone: a 10 000-long chain and an
// extended @acyclic base are freed with a balanced ledger, and the program means the same on JS,
// where the decorator has no effect.

@acyclic
class Link {
	next: Link | null = null;
	tag: int64;
	constructor(tag: int64) { this.tag = tag; }
}

@acyclic
class Base {
	next: Base | null = null;
	n: int32 = 1;
}

class Leaf extends Base { extra: int32 = 2; }

function chain(n: int32): Link {
	let head = new Link(0);
	for (let i: int32 = 1; i < n; i += 1) {
		const l = new Link(i);
		l.next = head;
		head = l;
	}
	return head;
}

function walk(head: Link): string {
	let count = 0;
	let sum: int64 = 0;
	let cur: Link | null = head;
	while (cur != null) {
		count += 1;
		sum += cur.tag;
		cur = cur.next;
	}
	return `chain ${count} sum ${sum}`;
}

function leaf(): int32 {
	const l = new Leaf();
	l.next = new Base();
	const b = l.next;
	return l.n + l.extra + (b != null ? b.n : 0) - 1;
}

console.log(walk(chain(10000)));
console.log(`leaf ${leaf()}`);
