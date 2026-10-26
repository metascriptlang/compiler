class Tree {
	left: Tree | null = null;
	right: Tree | null = null;
	value: int32 = 0;
}

function build(depth: int32, seed: int32): Tree {
	const node = new Tree();
	node.value = seed;
	if (depth > 0) {
		node.left = build(depth - 1, seed * 2);
		node.right = build(depth - 1, seed * 2 + 1);
	}
	return node;
}

function walk(node: Tree | null): int32 {
	if (node == null) return 0;
	return node.value % 7 + walk(node.left) + walk(node.right);
}

let total = 0;
for (let round = 0; round < 60; round += 1) total += walk(build(13, round + 1));
console.log(`tree ${total}`);
