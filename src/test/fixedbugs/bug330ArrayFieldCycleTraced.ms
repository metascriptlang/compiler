// bug330 — a class cycle that runs through a T[] field was judged acyclic
//
// Symptom:    `class Node { kids: Node[] }` with a.kids.push(b), b.kids.push(a):
//             Node's =trace skipped `kids` and its field release used msDecref,
//             so ORC could never see the cycle (audit lift-hooks-6 / runtime-rc-4).
//
// Root cause: canFormAcycle had no identity for a nameless array, so the origin
//             Ref<Array<Node>> keyed as "" and the back-edge test in the Array arm
//             never ran (reference: types.nim canFormAcycleAux, tySequence arm).
//
// Fix:        cycles.ms keys an array by its structural typeKey and gives the
//             Array arm the reference's back-edge + marker test.

import { compileToC } from "../helpers";

test "bug330: a T[] field that closes a class cycle is traced" {
	const src = `
class Node {
	other: Node | null = null;
	kids: Node[] = [];
}
const a = new Node();
const b = new Node();
a.kids.push(b);
b.kids.push(a);
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).kids), callback);");
		assert c.value.contains("msDecrefCyclic((*self).kids);");
	}
}

test "bug330: a T[][] field that closes a class cycle is traced" {
	const src = `
class Grid {
	cells: Grid[][] = [];
}
const a = new Grid();
const b = new Grid();
a.cells.push([b]);
b.cells.push([a]);
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).cells), callback);");
		assert c.value.contains("msDecrefCyclic((*self).cells);");
	}
}

test "bug330: a T[] field of an acyclic element stays untraced" {
	const src = `
class Leaf { name: string = ""; }
class Holder {
	leaves: Leaf[] = [];
}
const h = new Holder();
h.leaves.push(new Leaf());
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert !c.value.contains("msOrcTraceRef(&((*self).leaves), callback);");
		assert !c.value.contains("msDecrefCyclic((*self).leaves);");
	}
}
