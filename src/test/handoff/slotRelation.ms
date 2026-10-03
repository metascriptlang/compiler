import { strictErrorCount } from "./helpers";
import { compileToC, compileToJS } from "../helpers";

test "slot relation: the argument relation governs every storage boundary" {
	const pairs = [
		{ source: "string", target: "int32", accepted: false },
		{ source: "int32", target: "boolean", accepted: false },
		{ source: "boolean", target: "string", accepted: false },
		{ source: "bigint", target: "number", accepted: false },
		{ source: "number", target: "bigint", accepted: false },
		{ source: "int32", target: "int64", accepted: true },
		{ source: "int32", target: "float64", accepted: true },
		{ source: "int32", target: "uint32", accepted: false },
		{ source: "int32", target: "uint8", accepted: false },
		{ source: "uint8", target: "int32", accepted: true },
		{ source: "int64", target: "int32", accepted: false },
		{ source: "int16", target: "uint16", accepted: false },
		{ source: "uint8", target: "uint32", accepted: true },
		{ source: "int8", target: "int32", accepted: true },
		{ source: "float64", target: "int32", accepted: false },
		{ source: "int32 | string", target: "int32", accepted: false },
		{ source: "int32[]", target: "int64[]", accepted: false },
		{ source: "int32", target: "int32 | null", accepted: true },
		{ source: "string", target: "int32 | null", accepted: false },
		{ source: "int32", target: "string | null", accepted: false },
		{ source: "int32 | null", target: "int32", accepted: false },
		{ source: "Box", target: "int32", accepted: false },
		{ source: "int32", target: "Box", accepted: false },
		{ source: "int32[]", target: "int32", accepted: false },
		{ source: "Box | null", target: "Box", accepted: false },
		{ source: "null", target: "Box", accepted: false },
		{ source: "Value", target: "Ptr<Value>", accepted: false },
		{ source: "Value", target: "Ptr<Value> | null", accepted: false },
		{ source: "Other", target: "Ptr<Value> | null", accepted: false },
		{ source: "null", target: "Ptr<Value> | null", accepted: true },
		{ source: "Ptr<Value> | null", target: "Ptr<Value> | null", accepted: true },
		{ source: "Cell<int32>", target: "Cell<string>", accepted: false },
		{ source: "Cell<int32>", target: "Cell<int32>", accepted: true },
		{ source: "string", target: '"north" | "south"', accepted: false },
	];
	for (const pair of pairs) {
		const pre = "class Box { n: int32 = 1; } struct Value { n: int32; } struct Other { s: string; }\n"
			+ "class Cell<T> { v: T; constructor(v: T) { this.v = v; } }\n";
		const declaration = "function f(value: " + pair.source + "): void { const slot: " + pair.target + " = value; }";
		const assignment = "function f(value: " + pair.source + ", initial: " + pair.target + "): void { let slot: " + pair.target + " = initial; slot = value; }";
		const returned = "function f(value: " + pair.source + "): " + pair.target + " { return value; }";
		const argument = "function take(value: " + pair.target + "): void {} function f(value: " + pair.source + "): void { take(value); }";
		const field = "interface Holder { value: " + pair.target + "; } function f(value: " + pair.source + "): Holder { return { value: value }; }";
		for (const source of [declaration, assignment, returned, argument, field]) {
			const errors = strictErrorCount(pre + source);
			assert errors == (pair.accepted ? 0 : 1), pair.source + " -> " + pair.target + ": " + source;
		}
	}
}

test "slot relation: typed values and contextually fitted constants stay distinct" {
	const accepted = [
		"const a: int8 = -3; const b: int32 = a; const c: uint8 = 200; const d: uint32 = c;",
		"function take(n: int32): int32 { return n; } const wide: int64 = 3 as int64; const n = take(wide as int32) + take(-5);",
		"function choose(value: uint32): string { return \"u\"; } function choose(value: string): string { return value; } const signed: int32 = 3; const result = choose(4) + choose(signed as uint32);",
		"export const BASE: uint64 = 1 << 3; const K = 5; const U: uint32 = K * 2 + 1; const M: uint8 = (1 << 7) | 1;",
		"type Direction = \"row\" | \"column\"; type Style = { direction: Direction | null; width: float32 | null; on: boolean | null; byte: int8 | null }; const s: Style = { direction: \"row\", width: 3, on: true, byte: 5 }; s.direction = \"column\"; function pick(): Direction | null { return \"row\"; }",
		"const value: int32 | null = 7; const widened: int64 | null = value ?? 0;",
		"const u: uint8 = 3; const I: int32 = u + 1;",
		"class Box { n: int32 = 1; } function f(value: Box | null): int32 { if (value != null) { const slot: Box = value; return slot.n; } return 0; }",
	];
	for (const source of accepted) assert strictErrorCount(source) == 0, source;
	const rejected = [
		"const N: uint64 = 0 - 1;",
		"const B: uint8 = 1 << 9;",
		"const k: int32 = 5; const U: uint32 = k * 2;",
		"function big(): int8 | null { return 300; }",
		"function choose(value: uint32): string { return \"u\"; } function choose(value: string): string { return value; } const signed: int32 = -7; const result = choose(signed);",
	];
	for (const source of rejected) assert strictErrorCount(source) == 1, source;
}

test "slot relation: composite refusals report once at declarations, assignments and elements" {
	const classes = "class Source { a: int32 = 1; }\nclass Target { b: int32 = 2; }\nclass Cell<T> { v: T; constructor(v: T) { this.v = v; } }\n";
	const mismatches = [
		classes + "const x: Target = new Source();",
		classes + "const x: Cell<int32> = new Cell<string>(\"x\");",
		"struct Pair { x: int32; y: int32; }\nconst lit = { y: 1, x: 2 };\nconst x: Pair = lit;",
		"const x: int32 = null;",
		classes + "function f(): void { let x: Target = new Target(); x = new Source(); }",
		classes + "function f(): void { let x: Cell<int32> = new Cell<int32>(1); x = new Cell<string>(\"x\"); }",
		classes + "const xs: Target[] = [new Target(), new Source()];",
	];
	for (const source of mismatches) assert strictErrorCount(source) == 1, source;
}

test "slot relation: contextual fitting survives generic bodies and expression contexts" {
	const cases = [
		{ name: "contextual cast, void callback and rest argument", source: "class Base { n: int32 = 0; } class Derived extends Base {}\n"
			+ "function pick(c: boolean, a: Base, b: Base): Derived { return (c ? a : b) as Derived; }\n"
			+ "function effect(f: () => void): void { f(); } function run(c: boolean): void { const i: int32 = 7; effect(() => i + 1); console.log(c ? \"yes\" : \"no\"); }\n" },
	];
	for (const item of cases) {
		assert strictErrorCount(item.source) == 0, item.name;
		const c = compileToC(item.source);
		assert c.ok, item.name + (c.ok ? "" : ": " + c.error);
	}
	const genericBodies = [
		{ name: "unused generic body with a contextually typed empty array field", source: "interface Op<T> { v: T; } interface Queue<T> { ops: Op<T>[]; reset: boolean; } class Host<T> { attach(): Queue<T> { const q: Queue<T> = { ops: [], reset: false }; return q; } }\n" },
	];
	for (const item of genericBodies) assert strictErrorCount(item.source) == 0, item.name;
	const bad = "function via<T>(value: T): int32 { const n: int32 = value; return n; } const n = via<string>(\"a\");";
	assert strictErrorCount(bad) > 0;
	const js = compileToJS("function f(s: string): void { const n: int32 = s; }");
	assert !js.ok;
}

test "slot relation: brands widen to their base but never acquire identity implicitly" {
	const pre = "type Entity = string & { __brand: \"Entity\" }; type Other = string & { __brand: \"Other\" }; function take(value: Entity): string { return value as string; } ";
	assert strictErrorCount(pre + "function f(): string { return take(\"raw\"); }") > 0;
	assert strictErrorCount(pre + "function f(): string { const value = \"x\" as Other; return take(value); }") > 0;
	assert strictErrorCount(pre + "function f(): string { const value = \"x\" as Entity; const base: string = value; return take(value) + base; }") == 0;
}

test "slot relation: object shape errors reject the consumer without depending on display spelling" {
	for (const shape of ["{ a: int32 }", "{ p: { x: int32 } }"]) {
		assert strictErrorCount("function take(value: " + shape + "): void {} take(3);") > 0, shape;
	}
	assert strictErrorCount("const value = { a: 1, b: \"s\" }; const integer: int32 = value;") > 0;
}
