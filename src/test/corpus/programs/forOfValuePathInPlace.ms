// @stdout: field 3 flag 1 | row 6 g10 7 | calls 3 picks 1 | moved 3 | grown 3 nodes 5 | replaced 8
// note: a for-of over an indexed path from a symbol reads that path again at each element, with every index evaluated once before the loop (NIM-REF TR-26). The lowering put the iterable in a temp, which cursor inference copied whenever the body wrote through the same root (one heap copy per loop entry in void3d's syncWorld). A write to the index variable does not move the loop to another array; growing the outer array stays safe; replacing the iterated array is seen, as for a field path.

struct Node { children: Vec<int32>; flag: int32; }
struct Tree { nodes: Vec<Node>; }

let picks: int32 = 0;

function pick(): int32 {
	picks = picks + 1;
	return 0;
}

function field(ref t: Tree, i: int32): int32 {
	let sum: int32 = 0;
	for (const c of t.nodes[i].children) {
		t.nodes[c].flag = 1;
		sum = sum + c;
	}
	return sum;
}

function row(i: int32): string {
	let g: Vec<Vec<int32>> = [[1, 2, 3], [4, 5]];
	let sum: int32 = 0;
	for (const c of g[i]) {
		g[1][0] = 7;
		sum = sum + c;
	}
	return `row ${sum} g10 ${g[1][0]}`;
}

function called(ref t: Tree): int32 {
	let sum: int32 = 0;
	for (const c of t.nodes[pick()].children) {
		t.nodes[c].flag = 2;
		sum = sum + c;
	}
	return sum;
}

function moved(ref t: Tree): int32 {
	let i: int32 = 0;
	let sum: int32 = 0;
	for (const c of t.nodes[i].children) {
		i = 1;
		sum = sum + c;
	}
	return sum;
}

function grown(ref t: Tree): int32 {
	let sum: int32 = 0;
	for (const c of t.nodes[0].children) {
		t.nodes.push({ children: [9, 9, 9, 9], flag: 0 });
		sum = sum + c;
	}
	return sum;
}

function replaced(ref t: Tree): int32 {
	let sum: int32 = 0;
	for (const c of t.nodes[0].children) {
		t.nodes[0] = { children: [7, 7], flag: 0 };
		sum = sum + c;
	}
	return sum;
}

let tree: Tree = {
	nodes: [{ children: [1, 2], flag: 0 }, { children: [5], flag: 0 }, { children: [], flag: 0 }],
};
const a = `field ${field(tree, 0)} flag ${tree.nodes[1].flag}`;
const b = row(0);
const c = `calls ${called(tree)} picks ${picks}`;
const d = `moved ${moved(tree)}`;
const e = `grown ${grown(tree)} nodes ${tree.nodes.length}`;
let small: Tree = { nodes: [{ children: [1, 2], flag: 0 }] };
const f = `replaced ${replaced(small)}`;
console.log(`${a} | ${b} | ${c} | ${d} | ${e} | ${f}`);
