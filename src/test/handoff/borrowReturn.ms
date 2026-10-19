import { checkProjectDiagnostics } from "../helpers";

function errors(source: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

const rows = "struct Row { a: string; b: int32; }\n";
const escapes = "escapes its stack frame";
const notFirst = "is not the first parameter";
const notPath = "it is not a path expression";
const byValue = "which is passed by value";

test "borrowReturn: a view into a path rooted at the first parameter compiles" {
	assert errors(rows + "class Box { items: Row[] = []; at(i: int32): Borrow<Row> { return this.items[i]; } }", "") == 0;
	assert errors(rows + "class Box { items: Row[] = []; name(i: int32): Borrow<string> { return this.items[i].a; } }", "") == 0;
	assert errors("class List<T> { items: T[] = []; at(i: int32): Borrow<T> { return this.items[i]; } }", "") == 0;
	assert errors(rows + "function pick(rows: Row[], i: int32): Borrow<Row> { return rows[i]; }", "") == 0;
	assert errors(rows + "function pick(r: Borrow<Row>): Borrow<string> { return r.a; }", "") == 0;
	assert errors(rows + "function pick(ref r: Row): Borrow<int32> { return r.b; }", "") == 0;
}

test "borrowReturn: a view forwarded through another view call stays rooted at the first parameter" {
	assert errors(rows + "class Box { items: Row[] = []; at(i: int32): Borrow<Row> { return this.items[i]; } first(): Borrow<Row> { return this.at(0); } }", "") == 0;
}

test "borrowReturn: a local escapes its stack frame" {
	assert errors(rows + "function pick(): Borrow<Row> { const local: Row = { a: \"y\", b: 2 }; return local; }", escapes) == 1;
	assert errors(rows + "class Box { items: Row[] = []; at(i: int32): Borrow<Row> { const r: Row = this.items[i]; return r; } }", escapes) == 1;
}

test "borrowReturn: a parameter other than the first is refused" {
	assert errors(rows + "class Box { at(rows: Row[]): Borrow<Row> { return rows[0]; } }", notFirst) == 1;
	assert errors(rows + "function pick(a: Row[], b: Row[]): Borrow<Row> { return b[0]; }", notFirst) == 1;
}

test "borrowReturn: a call result or a literal is not a path expression" {
	assert errors(rows + "class Box { mk(): Row { return { a: \"q\", b: 1 }; } at(): Borrow<Row> { return this.mk(); } }", notPath) == 1;
	assert errors(rows + "class Box { at(): Borrow<Row> { return { a: \"z\", b: 2 }; } }", notPath) == 1;
}

test "borrowReturn: a module-level variable is not the first parameter" {
	assert errors(rows + "const g: Row = { a: \"g\", b: 0 };\nfunction pick(rows: Row[]): Borrow<Row> { return g; }", "must borrow from the first parameter") == 1;
}

test "borrowReturn: a first parameter passed by value would be borrowed from its copy" {
	assert errors(rows + "function pick(r: Row): Borrow<string> { return r.a; }", byValue) == 1;
	assert errors("function pick(s: string): Borrow<string> { return s; }", byValue) == 1;
	assert errors("function pick(n: int32): Borrow<int32> { return n; }", byValue) == 1;
}
