import { strictErrorCount } from "./helpers";
import { compileToC, compileToJS } from "../helpers";

test "aggregate relation: storage wrappers preserve element identity at every slot" {
	const pre = "class Animal { name: string = \"\"; } class Dog extends Animal { breed: string = \"\"; } class Box<T> { value: T; constructor(value: T) { this.value = value; } }\n";
	const pairs = [
		{ source: "Dog[]", target: "Animal[]", accepted: false },
		{ source: "Dog[]", target: "Span<Animal>", accepted: false },
		{ source: "Dog[2]", target: "Animal[2]", accepted: false },
		{ source: "Animal[]", target: "(Animal | null)[]", accepted: false },
		{ source: "Dog[]", target: "Dog[]", accepted: true },
		{ source: "Box<int32>", target: "Box<string>", accepted: false },
		{ source: "Box<int32>", target: "Box<int64>", accepted: false },
		{ source: "Box<string>", target: "Box<string>", accepted: true },
		{ source: "[int32, string]", target: "[string, int32]", accepted: false },
		{ source: "[int32, string]", target: "[int32, string]", accepted: true },
		{ source: "string | int32", target: "boolean | string", accepted: false },
		{ source: "string | int32", target: "string | int32 | boolean", accepted: false },
		{ source: "string | null", target: "int32 | boolean", accepted: false },
		{ source: "string | int32", target: "string | int32", accepted: true },
		{ source: "null | Animal", target: "Animal | null", accepted: true },
		{ source: "(x: int32) => int32", target: "(x: string) => int32", accepted: false },
		{ source: "(x: int32) => int32", target: "(x: int32) => int32", accepted: true },
		{ source: "Result<int32, string>", target: "Result<string, string>", accepted: false },
	];
	for (const pair of pairs) {
		const boundaries = [
			"function f(value: " + pair.source + "): void { const slot: " + pair.target + " = value; }",
			"function f(value: " + pair.source + ", initial: " + pair.target + "): void { let slot: " + pair.target + " = initial; slot = value; }",
			"function f(value: " + pair.source + "): " + pair.target + " { return value; }",
			"function take(value: " + pair.target + "): void {} function f(value: " + pair.source + "): void { take(value); }",
			"interface Holder { value: " + pair.target + "; } function f(value: " + pair.source + "): Holder { return { value: value }; }",
			"function f(value: " + pair.source + "): void { const slots: (" + pair.target + ")[] = [value]; }",
		];
		for (const source of boundaries) {
			const errors = strictErrorCount(pre + source);
			assert pair.accepted ? errors == 0 : errors > 0, pair.source + " -> " + pair.target + ": " + source;
		}
	}
}

test "aggregate relation: scalar inference cannot widen writable array elements in either argument order" {
	const pre = "class Animal { name: string = \"\"; } class Dog extends Animal { breed: string = \"\"; } const dogs: Dog[] = [new Dog()]; const animal = new Animal();\n";
	const rejected = [
		"function first<T>(xs: T[], value: T): T { xs.push(value); return xs[0]; } first(dogs, animal);",
		"function keep<T>(value: T, xs: T[]): void { xs.push(value); } keep(animal, dogs);",
		"class Box<T> { value: T; constructor(value: T) { this.value = value; } } function take(b: Box<int64>): string { return \"i\"; } function take(s: string): string { return s; } take(new Box<int32>(5));",
	];
	for (const source of rejected) assert strictErrorCount(pre + source) > 0, source;
	const source = pre + "function add(xs: Animal[]): void { xs.push(new Animal()); } function first<T>(xs: T[], value: T): T { xs.push(value); return xs[0]; } const pets: Animal[] = []; add(pets); add(dogs as Animal[]); const one: Animal = dogs[0]; const d = first(dogs, new Dog()); console.log(one.name.length + d.breed.length);";
	const c = compileToC(source);
	assert c.ok, c.error;
}

function nestedArray(depth: int32): string {
	let typeName = "int32";
	for (let i = 0; i < depth; i += 1) typeName = typeName + "[]";
	return typeName;
}

function nestedFunction(depth: int32, same: boolean): string {
	let source = "type A0 = (x: int32) => int32; type B0 = (x: " + (same ? "int32" : "string") + ") => int32;\n";
	for (let i = 1; i <= depth; i += 1) {
		source = source + "type A" + i.toString() + " = (x: A" + (i - 1).toString() + ") => int32;\n";
		source = source + "type B" + i.toString() + " = (x: B" + (i - 1).toString() + ") => int32;\n";
	}
	return source + "function take(f: B" + depth.toString() + "): int32 { return 1; } function make(): A" + depth.toString() + " { return (x: A" + (depth - 1).toString() + "): int32 => 0; } const result = take(make());";
}

test "aggregate relation: finite nesting is not a relation cycle" {
	for (const depth of [20, 25]) {
		assert strictErrorCount(nestedFunction(depth, false)) > 0, depth.toString();
		assert strictErrorCount(nestedFunction(depth, true)) == 0, depth.toString();
	}
	for (const depth of [40, 50, 100]) {
		const typeName = nestedArray(depth);
		const source = "function id(x: " + typeName + "): " + typeName + " { return x; } function f(y: " + typeName + "): " + typeName + " { const z: " + typeName + " = id(y); return z; }";
		assert strictErrorCount(source) == 0, depth.toString();
		assert strictErrorCount("function f(x: " + typeName + "): " + nestedArray(depth + 1) + " { return x; }") == 1, depth.toString();
	}
	const recursive = "interface Link { next: Link | null; value: int32; } function read(x: Link): int32 { return x.value; } const first: Link = { next: null, value: 1 }; const second: Link = { next: first, value: 2 }; const n = read(second);";
	assert strictErrorCount(recursive) == 0;
}

test "aggregate relation: equivalent nested object shapes reach overload consumers" {
	const pre = "enum Kind { A, B } type Data = { a: int32, x: { q: string } } | { b: string }; type AData = { a: int32, x: { q: string } }; type BData = { b: string }; function make(k: Kind.A, d: AData): string; function make(k: Kind.B, d: BData): string; function make(k: Kind, d: Data): string { return \"ok\"; }\n";
	for (const body of [
		"const d: Data = { b: \"s\" }; return make(Kind.B, d);",
		"const d: Data = { a: 1, x: { q: \"s\" } }; return make(Kind.A, d);",
	]) {
		const source = pre + "function f(): string { " + body + " } console.log(f());";
		const c = compileToC(source);
		assert c.ok, c.error;
		const js = compileToJS(source);
		assert js.ok, js.error;
	}
}

test "aggregate relation: structural fitting requires a layout prefix, not just matching field names" {
	const pairs = [
		{ source: "{ w: int32; v: string }", target: "{ w: int32; v: string }", accepted: true },
		{ source: "{ w: int32; v: string }", target: "{ w: int32 }", accepted: true },
		{ source: "{ v: string; w: int32 }", target: "{ w: int32; v: string }", accepted: false },
		{ source: "{ w: int32; v: string }", target: "{ v: string }", accepted: false },
		{ source: "Leaf", target: "{ v: string }", accepted: false },
	];
	for (const pair of pairs) {
		const pre = "class Leaf { w: int32 = 7; v: string = \"p\"; } type Target = " + pair.target + "; ";
		for (const body of [
			"function f(value: " + pair.source + "): void { const slot: Target = value; }",
			"class Box { value: Target; constructor(value: Target) { this.value = value; } } function f(value: " + pair.source + "): void { const box = new Box(value); }",
		]) {
			const errors = strictErrorCount(pre + body);
			assert pair.accepted ? errors == 0 : errors > 0, body;
		}
	}
}

test "aggregate relation: array methods respect element width and view capability" {
	const cases = [
		{ source: "function f(): void { const view = \"abc\".asBytes(); view.push(88); }", accepted: false },
		{ source: "function f(): void { const bytes: uint8[] = []; let value = 65; bytes.push(value); }", accepted: false },
		{ source: "function f(): void { const bytes: uint8[] = []; let value = 65; bytes.push(value as uint8); }", accepted: true },
		{ source: "function f(): void { const bytes: uint8[] = []; bytes.push(7); console.log(bytes.join(\",\")); }", accepted: false },
		{ source: "function f(): void { const numbers: number[] = [1, 2]; console.log(numbers.join(\",\")); }", accepted: true },
	];
	for (const item of cases) {
		const c = compileToC(item.source);
		assert c.ok == item.accepted, item.source + (c.ok ? "" : ": " + c.error);
	}
}

test "aggregate relation: inferred object literal layout remains significant" {
	assert strictErrorCount("type Target = { w: int32; v: string }; function f(): void { const literal = { v: \"q\", w: 3 }; const value: Target = literal; }") > 0;
	assert strictErrorCount("type Target = { w: int32; v: string }; function f(): void { const literal = { w: 3, v: \"q\" }; const value: Target = literal; const prefix: { w: int32 } = value; }") == 0;
}
