// @stdout: tree 0
// @stdout: wrapped 1
// @stdout: flat 3
// @serial
// @ledger-slack(TreeNode) 2
// @ledger-slack(msRefArrayRefCell) 2
// @ledger-slack(int32_tArrayRefCell) 3
// @ledger-slack(Tree) 2
// @ledger-slack(Holder) 1
// @ledger-slack(BoxHolder) 1
// @ledger-slack(FlatHolder) 1
// @ledger-slack(Flat) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: a cyclic graph moved into an actor constructor leaves the creating thread's roots, so the actor frees it over its own root set.

class TreeNode {
	items: int32[] = [];
	children: TreeNode[] = [];
}

class Tree {
	root: TreeNode = new TreeNode();
	grow(): void {
		const old = this.root;
		const fresh = new TreeNode();
		fresh.children.push(old);
		this.root = fresh;
	}
}

struct Boxed {
	label: string;
	tree: Tree;
}

class Flat {
	items: int32[] = [1, 2, 3];
}

actor Holder {
	tree: Tree;
	constructor(tree: Tree) { this.tree = tree; }
	replace(): int32 {
		this.tree = new Tree();
		return this.tree.root.children.length;
	}
}

actor BoxHolder {
	box: Boxed;
	constructor(box: Boxed) { this.box = box; }
	replace(): int32 {
		const depth = this.box.tree.root.children.length;
		this.box = { label: "next", tree: new Tree() };
		return depth;
	}
}

actor FlatHolder {
	flat: Flat;
	constructor(flat: Flat) { this.flat = flat; }
	replace(): int32 {
		const n = this.flat.items.length;
		this.flat = new Flat();
		return n;
	}
}

async function main(): Promise<void> {
	const tree = new Tree();
	tree.grow();
	tree.grow();
	const holder = new Holder(move tree);
	console.log(`tree ${await holder.replace()}`);

	const inner = new Tree();
	inner.grow();
	inner.grow();
	const boxed: Boxed = { label: "first", tree: inner };
	const boxHolder = new BoxHolder(move boxed);
	console.log(`wrapped ${await boxHolder.replace()}`);

	const flat = new Flat();
	const flatHolder = new FlatHolder(move flat);
	console.log(`flat ${await flatHolder.replace()}`);
}

await main();
