import { argv } from "std/process";

class Tree { v: int32 = 0; kids: Tree[] = []; }

function grow(depth: int32, v: int32): Tree {
	const t = new Tree();
	t.v = v;
	if (depth > 0) {
		t.kids.push(grow(depth - 1, v * 2));
		t.kids.push(grow(depth - 1, v * 2 + 1));
	}
	return t;
}

function eachKid(t: Tree, f: (k: Tree) => void): void {
	for (const k of t.kids) f(k);
}

function visitSum(root: Tree, weight: (t: Tree) => int32): int64 {
	let total: int64 = 0;
	const walk = (t: Tree): void => {
		total += weight(t);
		eachKid(t, walk);
	};
	walk(root);
	return total + weight(root);
}

function run(count: int32): int64 {
	const root = grow(4, 1);
	const scale: int32 = 3;
	const weight = (t: Tree): int32 => t.v * scale;
	let sum: int64 = 0;
	for (let i: int32 = 0; i < count; i++) sum += visitSum(root, weight);
	return sum;
}

const count: int32 = argv.length > 1 ? argv[1].parseInt() as int32 : 200000;
console.log(`closureVisit ${run(count)}`);
