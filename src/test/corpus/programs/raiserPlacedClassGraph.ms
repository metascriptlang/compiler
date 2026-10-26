class Leaf {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

class Branch {
	left: Leaf;
	right: Leaf;
	constructor(left: Leaf, right: Leaf) {
		this.left = left;
		this.right = right;
	}
}

function make(n: int32): Branch {
	return new Branch(new Leaf(n), new Leaf(n + 1));
}

function sum(b: Branch): int32 {
	return b.left.v + b.right.v;
}

function run(): void {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		const b = make(i);
		total += sum(b);
	}
	console.log(total);
	const keep = make(10);
	const alias = keep;
	keep.left = new Leaf(7);
	console.log(sum(alias));
	const shared = keep.right;
	keep.right = new Leaf(1);
	console.log(shared.v + sum(keep));
}

run();
