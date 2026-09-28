// @stdout: call 2/1 | local 2/1 | outermost 2/1 | middle 2/1 | two 2/2 | assign 2/1 | field 2/1 | for-of 3/1 | for-of middle 3/1
// note: a value moved out of an indexed path on its last read (a declaration, an assignment, a for-of over a fresh value) evaluates every index once, as JS does; the reset of the moved source reads the same evaluated index.

struct Node { kids: Vec<int32>; }
struct Tree { nodes: Vec<Node>; rows: Vec<Vec<int32>>; }
struct Forest { trees: Vec<Tree>; }
struct Holder { kids: Vec<int32>; }

let picks: int32 = 0;

function pick(): int32 {
	picks = picks + 1;
	return 0;
}

function mkTree(): Tree {
	return { nodes: [{ kids: [1, 2] }], rows: [[3, 4]] };
}

function mkForest(): Forest {
	return { trees: [mkTree()] };
}

function fromCall(): int32 {
	const kids = mkTree().nodes[pick()].kids;
	return kids.length;
}

function fromLocal(): int32 {
	const tree = mkTree();
	const kids = tree.nodes[pick()].kids;
	return kids.length;
}

function outermost(): int32 {
	const tree = mkTree();
	const row = tree.rows[pick()];
	return row.length;
}

function middle(): int32 {
	const forest = mkForest();
	const kids = forest.trees[pick()].nodes[0].kids;
	return kids.length;
}

function two(): int32 {
	const forest = mkForest();
	const kids = forest.trees[pick()].nodes[pick()].kids;
	return kids.length;
}

function assign(): int32 {
	const tree = mkTree();
	let kids: Vec<int32> = [9];
	kids = tree.nodes[pick()].kids;
	return kids.length;
}

function field(): int32 {
	const tree = mkTree();
	let holder: Holder = { kids: [9] };
	holder.kids = tree.nodes[pick()].kids;
	return holder.kids.length;
}

function forOf(): int32 {
	let sum: int32 = 0;
	for (const kid of mkTree().nodes[pick()].kids) sum = sum + kid;
	return sum;
}

function forOfMiddle(): int32 {
	let sum: int32 = 0;
	for (const kid of mkForest().trees[pick()].nodes[0].kids) sum = sum + kid;
	return sum;
}

function report(label: string, value: int32): string {
	const line = `${label} ${value}/${picks}`;
	picks = 0;
	return line;
}

const parts: string[] = [];
parts.push(report("call", fromCall()));
parts.push(report("local", fromLocal()));
parts.push(report("outermost", outermost()));
parts.push(report("middle", middle()));
parts.push(report("two", two()));
parts.push(report("assign", assign()));
parts.push(report("field", field()));
parts.push(report("for-of", forOf()));
parts.push(report("for-of middle", forOfMiddle()));
console.log(parts.join(" | "));
