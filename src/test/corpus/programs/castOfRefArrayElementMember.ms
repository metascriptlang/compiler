// @stdout: b a 2 root
class Tree {
	tag: string;
	children: Tree[] = [];
	constructor(tag: string) { this.tag = tag; }
}
function grown(): Tree {
	const root = new Tree("root");
	const mid = new Tree("mid");
	mid.children.push(new Tree("a"));
	mid.children.push(new Tree("b"));
	root.children.push(mid);
	return root;
}
const root = grown();
const leaf = (root.children[0] as Tree).children[1] as Tree;
const first = ((root.children[0] as Tree).children[0] as Tree).tag;
const count = (root.children[0] as Tree).children.length;
const kept: Tree[] = [root];
console.log(`${leaf.tag} ${first} ${count} ${(kept[0] as Tree).tag}`);
