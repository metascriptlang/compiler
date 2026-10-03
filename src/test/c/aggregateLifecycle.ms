import { compileToC } from "../helpers";

struct CycleShape {
	declarations: string;
	field: string;
	cyclic: boolean;
}

test "array fields are cycle edges only when their element graph reaches the owner" {
	const cases: CycleShape[] = [
		{ declarations: "class Node { other: Node | null = null; kids: Node[] = []; } const a = new Node(); const b = new Node(); a.kids.push(b); b.kids.push(a);", field: "kids", cyclic: true },
		{ declarations: "class Grid { cells: Grid[][] = []; } const a = new Grid(); const b = new Grid(); a.cells.push([b]); b.cells.push([a]);", field: "cells", cyclic: true },
		{ declarations: "class Leaf { name: string = \"\"; } class Holder { leaves: Leaf[] = []; } const h = new Holder(); h.leaves.push(new Leaf());", field: "leaves", cyclic: false },
	];
	for (const c of cases) {
		const result = compileToC(c.declarations);
		assert result.ok, result.ok ? "" : result.error;
		assert result.value.contains(`msOrcTraceRef(&((*self).${c.field}), callback);`) == c.cyclic, c.field + " trace";
		assert result.value.contains(`msDecrefCyclic((*self).${c.field});`) == c.cyclic, c.field + " release";
	}
}

function declaresItemArrayOp(c: string, op: string, params: string): boolean {
	for (const line of c.split("\n")) {
		if (line.startsWith("void Item__") && line.indexOf("Array" + op + "__") > 0 && line.endsWith(params)) return true;
	}
	return false;
}

test "hook discovery traverses tuple and generic element containers to the managed leaf" {
	for (const container of ["[Vec<Item>, int32]", "Pair<Vec<Item>>"]) {
		const result = compileToC(`
struct Item { s: string; n: int32; }
struct Pair<T> { a: T; k: int32; }
function rows(): Vec<${container}> { return []; }
const r = rows();
console.log(r.length);
`);
		assert result.ok, result.ok ? "" : result.error;
		assert declaresItemArrayOp(result.value, "Destroy", "Array* self);"), container + " destroy ABI";
		if (container == "[Vec<Item>, int32]") {
			assert declaresItemArrayOp(result.value, "Sink", "Array* src);"), container + " sink ABI";
		} else {
			assert declaresItemArrayOp(result.value, "Copy", "Array* src);"), container + " copy ABI";
		}
	}
}
