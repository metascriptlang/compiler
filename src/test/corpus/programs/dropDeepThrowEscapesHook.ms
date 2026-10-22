// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): the Raiser VM frees a 200 000-link list recursively and overflows its own native stack, on the base compiler as well
// @stdout: n 30 caught after 7
// @stdout: n 200000 caught after 7
// note: an error that escapes an onDestroy hook stops the drop at the same hook whether the drop is shallow or crosses the stack bound: the catch around the drop sees it after exactly the hooks that ran before it
let seen = 0;

struct Tag { id: number; }
function check(id: number): void {
	if (id == 7) throw new Error(`tag ${id}`);
}
function onDestroy(this t: Tag): void {
	check(t.id);
	seen += 1;
}

class Node {
	tag: Tag;
	next: Node | null = null;
	constructor(id: number) { this.tag = { id: id }; }
}

function build(n: number): Node {
	let h: Node | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Node(i);
		x.next = h;
		h = x;
	}
	return h!;
}

function run(n: number): void {
	let h: Node | null = build(n);
	seen = 0;
	try {
		h = null;
	} catch (e) {
		console.log(`n ${n} caught after ${seen}`);
	}
	seen = 0;
}

run(30);
run(200000);
