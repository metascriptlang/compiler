// @skip-js: C-only by design: onDestroy counts the DRC's destroys; JS frees nothing
// @stdout: leaves 500 branches 501 text 500
// @stdout: destroyed 1001
// note: an owned tree whose nodes are subclasses of one extended class is classified over its subclasses, so with no plain back edge in any of them it leaves the collector in a release build, and every node is destroyed once when the root goes.
let destroyed = 0;
class Node {
	kids: Owned<Node>[] = [];
	up: Unowned<Node> | null = null;
}
class Branch extends Node { depth: int32 = 0; }
class Leaf extends Node { text: string = ""; }
function onDestroy(this n: Node): void { destroyed++; }

function build(): void {
	const root = new Branch();
	let leaves = 0;
	let branches = 1;
	let text = 0;
	let at: Node = root;
	for (let i: int32 = 0; i < 500; i++) {
		const b = new Branch();
		b.depth = i + 1;
		b.up = at;
		const l = new Leaf();
		l.text = "x";
		l.up = b;
		b.kids.push(l);
		at.kids.push(b);
		at = b;
	}
	const walk: Node[] = [root];
	while (walk.length > 0) {
		const n = walk.pop();
		if (n instanceof Leaf) {
			leaves++;
			text += n.text.length;
		} else {
			if (n !== root) branches++;
		}
		for (const k of n.kids) walk.push(k);
	}
	console.log("leaves " + leaves.toString() + " branches " + branches.toString() + " text " + text.toString());
}

build();
console.log("destroyed " + destroyed.toString());
