import { strictErrorCount } from "./helpers";
import { compileToC, compileToJS } from "../helpers";

test "enumRelations: enum members resolve only in their declaring enum" {
	const cases = [
		{ name: "unknown enum member is rejected by the checker", source: "\nenum Color { Red, Green }\n\nexport function pick(): int32 {\n\treturn Color.Purple as int32;\n}\n", expected: -1 },
		{ name: "unknown enum member in a match arm is rejected", source: "\nenum Color { Red, Green }\n\nexport function name(c: Color): string {\n\treturn match (c) {\n\t\tColor.Red => \"r\",\n\t\tColor.Purple => \"p\",\n\t\t_ => \"x\",\n\t};\n}\n", expected: -1 },
		{ name: "existing enum member still compiles", source: "\nenum Color { Red, Green }\n\nexport function pick(): int32 {\n\treturn Color.Green as int32;\n}\n", expected: 0 },
		{ name: "declared extern enum member passes the checker", source: "\nextern enum Flags { A, B }\n\nexport function ok(): int32 { return Flags.A as int32; }\n", expected: 0 },
		{ name: "undeclared extern enum member is rejected", source: "\nextern enum Flags { A, B }\n\nexport function bad(): int32 { return Flags.C as int32; }\n", expected: -1 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "enumRelations: unknown operands require a concrete interpretation" {
	const cases = [
		{ name: "u + 1 is a checker error", source: "function f(u: unknown): void { const x = u + 1; }", expected: -1 },
		{ name: "comparison on unknown is a checker error", source: "function f(u: unknown): void { const b = u < 2; }", expected: -1 },
		{ name: "compound assignment on unknown is a checker error", source: "function f(): void { let u: unknown = null; u += 1; }", expected: -1 },
		{ name: "string concat with unknown is a checker error", source: "function f(u: unknown): void { const s = \"a\" + u; }", expected: -1 },
		{ name: "equality on unknown stays legal", source: "function f(u: unknown): boolean { return u === null; }", expected: 0 },
		{ name: "a narrowed operand stays legal", source: "class Box { n: number; }\nfunction f(u: unknown): number { return (u as Box).n + 1; }", expected: 0 },
		{ name: "assignment into an unknown local stays legal", source: "class Box { n: number; }\nfunction f(): void { let u: unknown = null; const b = new Box(); u = b as unknown; }", expected: 0 },
	];
	for (const item of cases) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
}

test "enumRelations: sets preserve their ordinal enum operand domain" {
	const cases = [
		{ name: "a member on the left of | joins the set", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; const t = E.B | s; console.log(t.has(E.B));", expected: 0 },
		{ name: "a member on the left of | joins the set", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; const n: int32 = E.B | s; console.log(n);", expected: -1 },
		{ name: "a set equals only a set over the same enum", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; const u: BitSet<E> = E.C | E.A; console.log(s == u, s != u);", expected: 0 },
		{ name: "a set equals only a set over the same enum", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; console.log(s == E.A);", expected: -1 },
		{ name: "a set equals only a set over the same enum", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; const t: BitSet<K> = K.X | K.Y; console.log(s != t);", expected: -1 },
		{ name: "ordering a set needs a declared operator", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; const u: BitSet<E> = E.C | E.A; console.log(s <= u);", expected: -1 },
		{ name: "ordering a set needs a declared operator", source: "enum E { A, B, C, D } enum K { X, Y } const s: BitSet<E> = E.A | E.C; const u: BitSet<E> = E.C | E.A; console.log(s < u);", expected: -1 },
		{ name: "the element must be an enum with ordinal members", source: "enum E { A, B, C, D } enum K { X, Y } const a: BitSet<uint8> = 0 as BitSet<uint8>; console.log(a.isEmpty());", expected: -1 },
		{ name: "the element must be an enum with ordinal members", source: "enum E { A, B, C, D } enum K { X, Y } enum H { X = 1, Y = 5 } const h: BitSet<H> = 0 as BitSet<H>; console.log(h.isEmpty());", expected: -1 },
		{ name: "the element must be an enum with ordinal members", source: "enum E { A, B, C, D } enum K { X, Y } const z: BitSet<E> = 0 as BitSet<E>; console.log(z.isEmpty());", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "enumRelations: equality and patterns preserve nominal domains" {
	const cases0 = [
		{ name: "a match arm of another enum is refused", source: "enum Color { Red, Green, Blue }\nenum Other { Blue, Green, Red }\nfunction f(c: Color): int32 { return match (c) { Other.Red => 1, Other.Green => 2, Other.Blue => 3 }; }\n", expected: -1 },
		{ name: "a switch case of another enum is refused", source: "enum Color { Red, Green, Blue }\nenum Other { Blue, Green, Red }\nfunction f(c: Color): int32 { switch (c) { case Other.Red: return 1; default: return 0; } }\n", expected: -1 },
		{ name: "comparing two enums or an enum and a string is refused", source: "enum Color { Red, Green, Blue }\nenum Other { Blue, Green, Red }\nfunction f(c: Color): boolean { return c == Other.Red; }\n", expected: -1 },
		{ name: "comparing two enums or an enum and a string is refused", source: "enum Color { Red, Green, Blue }\nenum Other { Blue, Green, Red }\nfunction f(c: Color): boolean { return c == \"Red\"; }\n", expected: -1 },
		{ name: "comparing two unrelated structs is refused", source: "struct A { x: int32; }\nstruct B { y: string; }\nfunction f(a: A, b: B): boolean { return a == b; }\n", expected: -1 },
		{ name: "an enum compared with an integer literal is refused", source: "enum Color { Red, Green, Blue }\nfunction f(c: Color): boolean { return c == 2; }\n", expected: -1 },
		{ name: "an integer variable compared with an enum is refused on either side", source: "enum Color { Red, Green, Blue }\nfunction f(c: Color, n: int64): boolean { return n != c; }\n", expected: -1 },
		{ name: "the ordinal compares through an explicit conversion", source: "enum Color { Red, Green, Blue }\nfunction f(c: Color): boolean { return (c as int32) == 2 || c == Color.Blue; }\n", expected: 0 },
	];
	for (const item of cases0) {
		const errors = strictErrorCount(item.source);
		assert item.expected < 0 ? errors > 0 : errors == item.expected, item.name;
	}
	const cases1 = [
		{ name: "the same enum, an enum and a number, and an exhaustive match stay accepted", source: "enum Color { Red, Green, Blue }\nenum Other { Blue, Green, Red }\nfunction f(c: Color): int32 { return match (c) { Color.Red => 1, Color.Green => 2, Color.Blue => 3 }; }\nfunction g(c: Color): boolean { return c == Color.Green || (c as int32) == 2; }\nstruct P { x: int32; }\nfunction h(a: P, b: P): boolean { return a == b; }\n", expected: 0 },
	];
	for (const item of cases1) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "enum relation: shared scalar representation never erases nominal identity" {
	const pre = "enum Color { Red, Green, Blue } interface Holder { color: Color; } function take(color: Color): int32 { return color as int32; } ";
	const values = [
		{ source: "1", accepted: false },
		{ source: "integer", accepted: false },
		{ source: "wide", accepted: false },
		{ source: "Color.Green", accepted: true },
		{ source: "1 as Color", accepted: true },
	];
	for (const value of values) {
		const declarations = pre + "const integer: int32 = 1; const wide: int64 = 1; ";
		for (const body of [
			"const color: Color = " + value.source + ";",
			"let color: Color = Color.Red; color = " + value.source + ";",
			"const holder: Holder = { color: " + value.source + " };",
			"const ordinal = take(" + value.source + ");",
			"function f(): Color { return " + value.source + "; }",
		]) {
			const errors = strictErrorCount(declarations + body);
			assert value.accepted ? errors == 0 : errors > 0, body;
		}
	}
}

test "enum relation: constant evaluation stops at calls, forward references and representation bounds" {
	const sources = [
		"function f(): int32 { return 1; } enum E { A = f() }",
		"enum E { A = B, B }",
		"enum E { A = 4294967296 }",
		"enum E { A = 1 << 32 }",
	];
	for (const source of sources) {
		const c = compileToC(source);
		assert !c.ok, source;
		const js = compileToJS(source);
		assert !js.ok, source;
	}
}

test "enum relation: unknown names are rejected after member and extension lookup" {
	const pre = "enum Mood { Calm, Angry } function label(this mood: Mood): uint8 { return (mood as int32) as uint8; } function first(this typeof Mood): Mood { return Mood.Calm; } ";
	const cases = [
		{ expression: "Mood.Bogus", accepted: false },
		{ expression: "Mood.bogus(1)", accepted: false },
		{ expression: "mood.bogus()", accepted: false },
		{ expression: "Mood.Calm", accepted: true },
		{ expression: "Mood.first()", accepted: true },
		{ expression: "mood.label()", accepted: true },
	];
	for (const item of cases) {
		const source = pre + "function f(): void { const mood = Mood.Angry; const result = " + item.expression + "; }";
		const errors = strictErrorCount(source);
		assert item.accepted ? errors == 0 : errors > 0, item.expression;
	}
}
