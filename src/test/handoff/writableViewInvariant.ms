import { hasError, strictErrorCount } from "./helpers";

const PRELUDE = `
class P { q: int32 = 4; }
class Base { id: int32 = 0; }
class Left extends Base { l: int32 = 1; }
class Right extends Base { r: int32 = 2; }
`;

test "writableViewInvariant: a writable view widening an int32 or string field to unknown is refused" {
	const rows = [
		{ name: "int32", field: "int32", value: "1" },
		{ name: "string", field: "string", value: "\"s\"" },
	];
	for (const row of rows) {
		const source = PRELUDE +
			"type S = { x: " + row.field + "; z: int32 };\n" +
			"type T = { x: unknown };\n" +
			"function w(t: T): void { t.x = new P(); }\n" +
			"const s: S = { x: " + row.value + ", z: 2 };\n" +
			"w(s);";
		assert hasError(source, "declare the parameter Readonly<"), row.name;
		assert hasError(source, "or give the field its exact type " + row.field), row.name;
	}
}

test "writableViewInvariant: a writable view widening a base-class field is refused, one level deeper too" {
	const flat = PRELUDE +
		"type S = { x: Left; z: int32 };\n" +
		"type T = { x: Base };\n" +
		"function w(t: T): void { t.x = new Right(); }\n" +
		"const s: S = { x: new Left(), z: 2 };\n" +
		"w(s);";
	assert hasError(flat, "field 'x' is Left here but Base");
	const nested = PRELUDE +
		"type SIn = { x: Left };\n" +
		"type TIn = { x: Base };\n" +
		"type S = { in: SIn; z: int32 };\n" +
		"type T = { in: TIn };\n" +
		"function w(t: T): void { t.in.x = new Right(); }\n" +
		"const s: S = { in: { x: new Left() }, z: 2 };\n" +
		"w(s);";
	assert hasError(nested, "field 'in'");
}

test "writableViewInvariant: a Readonly view and an identical-type view still pass" {
	const readonlyView = PRELUDE +
		"type S = { x: int32; z: int32 };\n" +
		"type T = { x: unknown };\n" +
		"function r(t: Readonly<T>): void { console.log(t.x); }\n" +
		"const s: S = { x: 1, z: 2 };\n" +
		"r(s);";
	assert strictErrorCount(readonlyView) == 0;
	const identical = PRELUDE +
		"type S = { x: Base; z: int32 };\n" +
		"type T = { x: Base };\n" +
		"function w(t: T): void { t.x = new Right(); }\n" +
		"const s: S = { x: new Left(), z: 2 };\n" +
		"w(s);";
	assert strictErrorCount(identical) == 0;
}

test "writableViewInvariant: a literal field read as its wider type through a writable view is refused" {
	const rows = [
		{ name: "string literal", narrow: "\"circle\"", wide: "string", value: "\"circle\"", write: "\"square\"", prelude: "" },
		{ name: "literal union", narrow: "\"circle\" | \"square\"", wide: "\"circle\" | \"square\" | \"tri\"", value: "\"circle\"", write: "\"tri\"", prelude: "" },
		{ name: "boolean literal", narrow: "true", wide: "boolean", value: "true", write: "false", prelude: "" },
		{ name: "enum member", narrow: "E.A", wide: "E", value: "E.A", write: "E.B", prelude: "enum E { A, B }\n" },
	];
	for (const row of rows) {
		const source = row.prelude +
			"type S = { k: " + row.narrow + "; z: int32 };\n" +
			"type T = { k: " + row.wide + " };\n" +
			"function w(t: T): void { t.k = " + row.write + "; }\n" +
			"const s: S = { k: " + row.value + ", z: 2 };\n" +
			"w(s);";
		assert hasError(source, "declare the parameter Readonly<"), row.name;
		const readOnly = row.prelude +
			"type S = { k: " + row.narrow + "; z: int32 };\n" +
			"type T = { k: " + row.wide + " };\n" +
			"function r(t: Readonly<T>): void { console.log(t.k); }\n" +
			"const s: S = { k: " + row.value + ", z: 2 };\n" +
			"r(s);";
		assert strictErrorCount(readOnly) == 0, row.name;
	}
}

test "writableViewInvariant: an array of one literal is not an array of its wider union" {
	const source = "type Kind = \"a\" | \"b\";\n" +
		"function push(xs: Kind[]): void { xs.push(\"b\"); }\n" +
		"const only: \"a\"[] = [\"a\"];\n" +
		"push(only);";
	assert hasError(source, "Argument type mismatch in 'push'");
}

test "writableViewInvariant: a nullable literal union is copied into its wider nullable, not aliased" {
	const source = "function show(s: string | null): string { return s ?? \"none\"; }\n" +
		"function pick(): \"a\" | \"b\" | null { return \"a\"; }\n" +
		"const v: \"a\" | \"b\" | null = pick();\n" +
		"console.log(show(v));";
	assert strictErrorCount(source) == 0;
}
