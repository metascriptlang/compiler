import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const CLASSES = `
class Shape { n: int32 = 1; }
class Cell extends Shape { m: int32 = 2; }
const K: Readonly<Shape> = new Cell();
const C: Readonly<Cell> = new Cell();
`;

function bothBackends(body: string): string[] {
	const source = CLASSES + body;
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/narrow.ms", entrySource: source }], "test/narrow.ms");
	return [c.ok ? "" : c.error, js.startsWith("ERROR:") ? js : ""];
}

test "readonlyNarrowing: a type predicate or instanceof narrows a read-only view to a read-only view of its target" {
	const refused = [
		"function lie(x: Readonly<Cell> | Cell): x is Cell { return true; }\nconst v: Readonly<Cell> | Cell = C;\nif (lie(v)) { v.m = 5; }",
		"function lie(x: Readonly<Cell> | Cell): x is Cell { return true; }\nconst v: Readonly<Cell> | Cell = C;\nif (!lie(v)) { } else { v.m = 5; }",
		"function lie(x: Readonly<Cell>): x is Cell { return true; }\nif (lie(C)) { C.m = 5; }",
		"function isCell(x: Readonly<Shape>): x is Cell { return true; }\nif (isCell(K)) { K.m = 5; }",
		"function lie(x: Readonly<Cell> | Cell): asserts x is Cell { }\nconst v: Readonly<Cell> | Cell = C;\nlie(v); v.m = 5;",
		"if (K instanceof Cell) { K.m = 5; }",
	];
	for (const body of refused) {
		const errors = bothBackends(body);
		assert errors[0].contains("cannot write through Readonly<Cell>"), "C: " + body + "\n" + errors[0];
		assert errors[1].contains("cannot write through Readonly<Cell>"), "JS: " + body + "\n" + errors[1];
	}
}

test "readonlyNarrowing: reads through a narrowed view and writes through a narrowed mutable union compile" {
	const legal = [
		"function isCell(x: Readonly<Shape>): x is Cell { return true; }\nif (isCell(K)) { console.log(K.m); }",
		"if (K instanceof Cell) { console.log(K.m); }",
		"function isRo(x: Readonly<Cell> | Cell): x is Readonly<Cell> { return true; }\nconst v: Readonly<Cell> | Cell = C;\nif (isRo(v)) { console.log(v.m); }",
		"class A { a: int32 = 1; }\nfunction isCell(x: Cell | A): x is Cell { return x instanceof Cell; }\nconst v: Cell | A = new Cell();\nif (isCell(v)) { v.m = 5; }",
		"function isCell(x: Shape): x is Cell { return x instanceof Cell; }\nconst s: Shape = new Cell();\nif (isCell(s)) { s.m = 5; }",
	];
	for (const body of legal) {
		const errors = bothBackends(body);
		assert errors[0] == "", "C: " + body + "\n" + errors[0];
		assert errors[1] == "", "JS: " + body + "\n" + errors[1];
	}
}
