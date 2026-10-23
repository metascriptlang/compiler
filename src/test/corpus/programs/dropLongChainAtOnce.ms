// @xfail(raiser): the Raiser VM frees a 1 000 000-link list recursively and overflows its own native stack, on the base compiler as well
// @stdout: chain 1000000 sum 499999500000
// @stdout: tree depth 300000 nodes 600001
// @stdout: pairs 500000 links 999999
// note: dropping the last reference to a 1 000 000-link list, and to a tree whose deepest path is 300 000 nodes through child arrays, and to a 999 999-link list alternating two classes that point at each other, frees every node without overflowing the native stack: past the thread's stack bound the destroy walks the rest with an explicit stack
class Link {
	next: Link | null = null;
	v: number = 0;
}

class Even {
	odd: Odd | null = null;
}

class Odd {
	even: Even | null = null;
}

function pairs(n: number): Even {
	let head = new Even();
	for (let i = 1; i < n; i++) {
		const odd = new Odd();
		odd.even = head;
		const even = new Even();
		even.odd = odd;
		head = even;
	}
	return head;
}

function links(head: Even): number {
	let n: number = 1;
	let at: Even | null = head;
	while (at != null && at.odd != null) {
		n += 2;
		at = at.odd!.even;
	}
	return n;
}

class Tree {
	kids: Tree[] = [];
	v: number = 0;
}

function chain(n: number): Link {
	let head = new Link();
	for (let i = 1; i < n; i++) {
		const link = new Link();
		link.v = i;
		link.next = head;
		head = link;
	}
	return head;
}

function sum(head: Link): number {
	let s: number = 0;
	let p: Link | null = head;
	while (p != null) {
		s += p.v;
		p = p.next;
	}
	return s;
}

function tree(depth: number): Tree {
	const root = new Tree();
	let at = root;
	for (let d = 0; d < depth; d++) {
		const deep = new Tree();
		at.kids.push(new Tree());
		at.kids.push(deep);
		at = deep;
	}
	return root;
}

function count(root: Tree): number {
	let n: number = 0;
	const todo: Tree[] = [root];
	while (todo.length > 0) {
		const t = todo.pop()!;
		n += 1;
		for (const k of t.kids) todo.push(k);
	}
	return n;
}

{
	const head = chain(1000000);
	console.log("chain 1000000 sum " + sum(head).toString());
}

{
	const root = tree(300000);
	console.log("tree depth 300000 nodes " + count(root).toString());
}

{
	const head = pairs(500000);
	console.log("pairs 500000 links " + links(head).toString());
}
