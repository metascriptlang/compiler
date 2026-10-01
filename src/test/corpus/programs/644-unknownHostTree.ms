// @stdout: host-tree nodes=3000 depth=3 last=c2 plain=plain

type HostNode = unknown;

class TreeNode {
	tag: string;
	children: TreeNode[] = [];
	constructor(tag: string) { this.tag = tag; }
}

function createElement(tag: string): HostNode {
	return new TreeNode(tag);
}

function appendChild(parent: HostNode, child: HostNode): void {
	(parent as TreeNode).children.push(child as TreeNode);
}

function buildOnce(): string {
	const root = createElement("root");
	for (let i = 0; i < 3; i += 1) {
		appendChild(root, createElement("c" + i.toString()));
	}
	const kids = (root as TreeNode).children;
	return kids[kids.length - 1].tag;
}

function depthOf(n: HostNode): int32 {
	let d = 1 as int32;
	let cur = n as TreeNode;
	while (cur.children.length > 0) {
		cur = cur.children[0];
		d += 1;
	}
	return d;
}

function chain(): int32 {
	const a = createElement("a");
	const b = createElement("b");
	appendChild(b, createElement("c"));
	appendChild(a, b);
	return depthOf(a);
}

function main(): void {
	const plain = new TreeNode("plain");
	let nodes = 0 as int32;
	let last = "";
	for (let r = 0; r < 1000; r += 1) {
		last = buildOnce();
		nodes += 3;
	}
	let depth = 0 as int32;
	for (let r = 0; r < 500; r += 1) depth = chain();
	console.log(`host-tree nodes=${nodes} depth=${depth} last=${last} plain=${plain.tag}`);
}
main();
