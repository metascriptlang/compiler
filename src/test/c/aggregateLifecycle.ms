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
		assert result.value.contains(`msOrcTraceRef((&((*self).${c.field})), callback);`) == c.cyclic, c.field + " trace";
		assert result.value.contains(`msDecrefCyclicEdge(self, (*self).${c.field})`) == c.cyclic, c.field + " release";
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

test "a union-of-literals field is a string with string hooks in a struct that has no other string" {
	const result = compileToC(`
type Fmt = "a" | "b";
struct Slot { k: Fmt; n: int32; }
struct Outer { slot: Slot; tag: int32; }
function dup(o: Outer): Outer { const t = o; return t; }
function run(): int32 { const grid: Slot[2] = [{ k: "a", n: 1 }, { k: "b", n: 2 }]; return dup({ slot: grid[0], tag: 1 }).tag; }
console.log(run());
`);
	assert result.ok, result.ok ? "" : result.error;
	assert result.value.contains("msStringDecref((*self).k);"), "owner destroy releases the union field";
	assert result.value.contains("msStringCopy((&((*dest).k)), (*src).k);"), "owner copy retains the union field";
	assert result.value.contains("Destroy((&((*self).slot)));"), "a struct in a struct runs the field's hooks";
	assert result.value.contains("Destroy((&(grid_1_)));"), "a sized array of the struct is destroyed with its owner";
}

test "a literal member beside null or another type makes its owner a string owner too" {
	for (const field of ["\"a\" | \"b\" | null", "\"a\" | \"b\" | int32", "\"a\""]) {
		const result = compileToC(`
struct Slot { k: ${field}; n: int32; }
function dup(s: Slot): Slot { const t = s; return t; }
console.log(dup({ k: "a", n: 1 }).n);
`);
		assert result.ok, result.ok ? "" : result.error;
		assert result.value.contains("Copy((&(dollarborrow_"), field + " copy hook";
	}
}
