import { Node, childCount, childAt } from "std/meta";

function leaves(n: Node): int32 {
	const c = childCount(n);
	if (c == 0) return 1;
	let total: int32 = 0;
	for (let i: int32 = 0; i < c; i = i + 1) total = total + leaves(childAt(n, i));
	return total;
}

macro repeatedLeaves(e: Node, rounds: Node): Node {
	let total: int32 = 0;
	for (let r: int32 = 0; r < 200; r = r + 1) total = total + leaves(e);
	return quote { splice(total) };
}

function f(): number { return 3; }

test "macro host calls: a macro reaches the same AST bridge from many calls in one loop" {
	const sum: int32 = repeatedLeaves(f() + 1 + 2, 0);
	assert sum == 200 * 3;
}
