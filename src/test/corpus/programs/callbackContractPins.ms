// @stdout: 11011 31
// note: a callback that writes nothing the reader holds runs the uncounted reader body; one that replaces the array the reader walks runs the body that keeps the element pinned.
class Tree { v: int32 = 0; kids: Tree[] = []; tag: string = ""; }

function forEachKid(t: Tree, cb: (k: Tree) => void): void {
	for (let i = 0; i < t.kids.length; i++) cb(t.kids[i]);
}

function build(depth: int32, v: int32): Tree {
	const t = new Tree();
	t.v = v;
	t.tag = `node-${"z".repeat(24)}-${v}`;
	if (depth > 0) for (let i = 0; i < 3; i++) t.kids.push(build(depth - 1, v * 3 + i));
	return t;
}

function sum(t: Tree): int32 {
	let s = t.v;
	forEachKid(t, (k: Tree): void => { s += sum(k); });
	return s;
}

let root = build(4, 1);

function pruneParent(t: Tree): int32 {
	let seen: int32 = 0;
	forEachKid(t, (k: Tree): void => {
		if (seen == 0) t.kids = [];
		seen += k.tag.length;
	});
	return seen;
}

console.log(`${sum(root)} ${pruneParent(root)}`);
