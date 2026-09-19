// Phase 9: converter boundary lowering — docs/JSX-ROADMAP.md Phase 9,
// docs/LANG.md "Converter Declarations", docs/LANG-JSX.md "Boundary Lowering via Converter".
//
// A `converter` is a third routine kind: a compile-time macro-engine body the COMPILER
// invokes when a compile-time Node expression reaches a settled expected-runtime-type
// position (return / resolved call arg / annotated decl). Source type restricted to `Node`;
// result is re-checked in place; never applied inside overload scoring.

import { compileToC, compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { resetAllSideChannels } from "../../parser/context";
import { printNode } from "../../compiler/fmt/printer/index";
import { formatDoc } from "../../compiler/fmt/layout";
import { defaultFormatOptions } from "../../compiler/fmt/options";

function fmtSource(source: string): string {
	resetAllSideChannels();
	const parsed = parseSource(source);
	if (!parsed.ok) return "";
	const opts = defaultFormatOptions();
	opts.source = source;
	return formatDoc(printNode(parsed.value, opts), opts);
}

// Shared converter: any JSX node → the number literal 7.
const CONV = `
import { Node, NodeKind } from "std/meta";

export converter toNum(n: Node): number {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}
`;

// ===== 9.1 declaration =====

test "converter: decl parses and compiles when unused" {
	const c = compileToCWithStd(CONV + "function main(): void { }");
	assert c.ok;
}

const SECONDS = `
export type Seconds = distinct float64;
`;

function errorOf(source: string): string {
	const c = compileToCWithStd(source);
	return c.ok ? "" : c.error;
}

test "converter: runtime source declares in the module owning its target" {
	const e = errorOf(SECONDS + `
export converter toSeconds(n: float64): Seconds { return n as Seconds; }
const s = toSeconds(1.5);
`);
	assert e == "", e;
}

test "converter: runtime source declares in the module owning its source" {
	const e = errorOf(`
export interface Box { n: int32; }
export converter boxToInt(b: Box): int32 { return b.n; }
const b: Box = { n: 3 };
const n = boxToInt(b);
`);
	assert e == "", e;
}

test "converter: runtime source owns a Ref alias of its own struct" {
	const e = errorOf(`
export struct Cell { n: int32; }
export type CellRef = Ref<Cell>;
export converter cellToInt(c: CellRef): int32 { return c.n; }
`);
	assert e == "", e;
}

test "converter: runtime source owns the nullable target it declares" {
	const e = errorOf(SECONDS + `
export converter toSeconds(n: float64): Seconds | null { return n as Seconds; }
`);
	assert e == "", e;
}

test "converter: runtime source owning neither type is rejected" {
	const e = errorOf(`
export converter numToBool(n: float64): boolean { return n != 0; }
`);
	assert e.contains("converter 'numToBool' must be declared in the module that declares 'float64' or 'boolean'"), e;
}

test "converter: runtime converter for a type of another module is rejected" {
	const entries: MapEntry[] = [
		{ entryPath: "src/time.ms", entrySource: SECONDS },
		{ entryPath: "src/main.ms", entrySource: `
			import { Seconds } from "./time";
			export converter toSeconds(n: float64): Seconds { return n as Seconds; }
		` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert cCode.contains("converter 'toSeconds' must be declared in the module that declares 'float64' or 'Seconds'"), cCode;
}

test "converter: runtime converter with a default parameter is rejected" {
	const e = errorOf(SECONDS + `
export converter toSeconds(n: float64 = 0): Seconds { return n as Seconds; }
`);
	assert e.contains("converter 'toSeconds' parameter cannot have a default value"), e;
}

test "converter: runtime converter with two parameters is rejected" {
	const e = errorOf(SECONDS + `
export converter toSeconds(n: float64, m: float64): Seconds { return n as Seconds; }
`);
	assert e.contains("converter 'toSeconds' must take exactly one parameter"), e;
}

test "converter: generic runtime converter is rejected" {
	const e = errorOf(SECONDS + `
export converter toSeconds<T>(n: T): Seconds { return 0 as Seconds; }
`);
	assert e.contains("converter 'toSeconds' cannot be generic"), e;
}

test "converter: runtime converter inside a function is rejected" {
	const e = errorOf(SECONDS + `
function outer(): void {
	converter toSeconds(n: float64): Seconds { return n as Seconds; }
}
outer();
`);
	assert e.contains("converter 'toSeconds' is only allowed at module level"), e;
}

test "converter: fmt preserves the converter keyword on a runtime source" {
	const out = fmtSource("export converter toSeconds(n: float64): Seconds { return n as Seconds; }");
	assert out.contains("converter toSeconds(n: float64): Seconds"), out;
}

const BOX = `
export interface Box { n: int32; }
export converter boxToInt(b: Box): int32 { return b.n; }
const b: Box = { n: 3 };
`;

test "converter: runtime converter applies at a typed slot" {
	const e = errorOf(BOX + `const n: int32 = b;`);
	assert e == "", e;
}

test "converter: runtime converter applies at an argument of a single-signature call" {
	const e = errorOf(BOX + `
function take(n: int32): int32 { return n; }
const n = take(b);
`);
	assert e == "", e;
}

test "converter: runtime converter applies at a return" {
	const e = errorOf(BOX + `
function read(x: Box): int32 { return x; }
const n = read(b);
`);
	assert e == "", e;
}

test "converter: runtime converter applies at an as-conversion" {
	const c = compileToCWithStd(BOX + `const n = b as int32;`);
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert c.value.contains("boxToInt__") && c.value.contains("_u0(b__"), c.value;
}

function twoMeters(use: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "src/a.ms", entrySource: `
export type Meters = distinct float64;
export converter metersToText(m: Meters): string { return "a"; }
` },
		{ entryPath: "src/b.ms", entrySource: `
export type Meters = distinct float64;
` },
		{ entryPath: "src/main.ms", entrySource: `
import { Meters, metersToText } from "./a";
import { Meters as OtherMeters } from "./b";
const a = 1.0 as Meters;
const o = 2.0 as OtherMeters;
` + use },
	];
	return compileProjectToCWithStd(entries, "src/main.ms");
}

test "converter: runtime converter applies to the type it was declared for" {
	const cCode = twoMeters("const s: string = a;");
	assert !cCode.contains("ERROR:"), cCode;
}

test "converter: runtime converter skips a same-named type of another module" {
	const cCode = twoMeters("const s: string = o;");
	assert cCode.contains("Type 'Meters' is not assignable to type 'string'"), cCode;
}

test "converter: runtime converter fills a nullable slot of its target" {
	const e = errorOf(SECONDS + `
export converter toSeconds(n: float64): Seconds { return n as Seconds; }
const x: float64 = 1.5;
const s: Seconds | null = x;
`);
	assert e == "", e;
}

test "converter: runtime converter matches a type imported by a second path" {
	const c = compileToCWithStd(`
import { JsonValue } from "std/serialize/json";
function text(a: JsonValue): string { return a as string; }
`);
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert c.value.contains("jsonToString"), c.value;
}

test "converter: two runtime converters for one pair are an error" {
	const e = errorOf(BOX + `
export converter boxToIntAgain(x: Box): int32 { return x.n + 1; }
const n: int32 = b;
`);
	assert e.contains("'boxToInt' and 'boxToIntAgain' both convert 'Box' to 'int32'"), e;
}

test "converter: runtime converters do not chain" {
	const e = errorOf(SECONDS + `
export type Minutes = distinct float64;
export converter toSeconds(n: float64): Seconds { return n as Seconds; }
export converter toMinutes(s: Seconds): Minutes { return ((s as float64) / 60.0) as Minutes; }
const x: float64 = 120.0;
const m: Minutes = x;
`);
	assert e.contains("Minutes"), e;
}

test "converter: runtime converter stays out of an overloaded call" {
	const e = errorOf(BOX + `
function pick(n: int32): int32 { return n; }
function pick(s: string): int32 { return 0; }
const n = pick(b);
`);
	assert e != "", e;
}

test "converter: runtime converter does not apply inside its own body" {
	const e = errorOf(`
export interface Box { n: int32; }
export converter boxToInt(b: Box): int32 {
	const n: int32 = b;
	return n;
}
`);
	assert e.contains("'boxToInt' does not apply inside its own body"), e;
}

test "converter: a helper the converter calls cannot apply that converter" {
	const e = errorOf(`
export interface Box { n: int32; }
function half(x: Box): int32 {
	const n: int32 = x;
	return n / 2;
}
export converter boxToInt(b: Box): int32 { return half(b) * 2; }
`);
	assert e.contains("'boxToInt' is applied implicitly in 'half', which 'boxToInt' reaches through its calls"), e;
}

test "converter: a helper the converter calls may apply another converter" {
	const e = errorOf(`
export interface Box { n: int32; }
export converter boxToText(x: Box): string { return "box"; }
function label(x: Box): string {
	const s: string = x;
	return s;
}
export converter boxToInt(b: Box): int32 { return label(b).length; }
const n: int32 = { n: 1 } as Box;
`);
	assert e == "", e;
}

test "converter: runtime converter reads an operand against a typed other side" {
	const e = errorOf(BOX + `
const a = b + 1;
const c = 1 + b;
const d = b * 2;
`);
	assert e == "", e;
}

test "converter: runtime converter reads the operand of a compound assignment" {
	const e = errorOf(BOX + `
let t: int32 = 0;
t += b;
`);
	assert e == "", e;
}

test "converter: runtime converter reads an operand of a comparison" {
	const c = compileToCWithStd(BOX + `const g = b > 2;`);
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert c.value.contains("_u0(b__"), c.value;
}

test "converter: runtime converter reads an operand of a string concatenation" {
	const c = compileToCWithStd(`
export interface Box { n: int32; }
export converter boxToText(x: Box): string { return "box"; }
const b: Box = { n: 3 };
const s = "n=" + b;
`);
	assert c.ok, c.ok ? "" : c.error;
	if (c.ok) assert c.value.contains("_u0(b__"), c.value;
}

test "converter: two converter sources in one operation stay an error" {
	const e = errorOf(BOX + `
const o: Box = { n: 4 };
const s = b + o;
`);
	assert e != "", e;
}

test "converter: runtime converter does not serve a receiver" {
	const e = errorOf(`
export interface Box { n: int32; }
export converter boxToText(x: Box): string { return "box"; }
const b: Box = { n: 3 };
const l = b.length;
`);
	assert e.contains("length"), e;
}

test "converter: missing return annotation is rejected" {
	const c = compileToC(`
import { Node } from "std/meta";
export converter bad(n: Node) {
	return n;
}
function main(): void { }
`);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("return type"); }
}

test "converter: more than one parameter is rejected" {
	const c = compileToC(`
import { Node } from "std/meta";
export converter bad(a: Node, b: Node): number {
	return a;
}
function main(): void { }
`);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("exactly one parameter"); }
}

// ===== 9.3 application at settled expected-type positions =====

test "converter: annotated decl boundary lowers JSX" {
	const c = compileToCWithStd(CONV + "function main(): void { const x: number = <a/>; }");
	assert c.ok;
}

test "converter: return-position boundary lowers JSX" {
	const c = compileToCWithStd(CONV + `
function view(): number { return <a/>; }
function main(): void { const x = view(); }
`);
	assert c.ok;
}

test "converter: resolved call-arg boundary lowers JSX" {
	const c = compileToCWithStd(CONV + `
function use(x: number): number { return x; }
function main(): void { const y = use(<a/>); }
`);
	assert c.ok;
}

test "converter: fragment lowers at annotated decl boundary" {
	const c = compileToCWithStd(CONV + "function main(): void { const x: number = <></>; }");
	assert c.ok;
}

test "converter: no boundary — bare-statement JSX still errors" {
	const c = compileToCWithStd(CONV + "function main(): void { <a/>; }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "converter: target mismatch — no application, normal error" {
	const c = compileToCWithStd(CONV + "function main(): void { const s: string = <a/>; }");
	assert !c.ok;
}

test "converter: explicit call stays legal" {
	const c = compileToCWithStd(CONV + "function main(): void { const x: number = toNum(<a/>); }");
	assert c.ok;
}

// ===== fmt: a formatter that rewrites `converter` to `macro` silently changes the
// routine kind and drops the target type — the whole boundary contract. =====

test "converter: fmt preserves the converter keyword and target type" {
	const out = fmtSource("export converter toNum(n: Node): number { return n; }");
	assert out.contains("converter toNum");
	assert out.contains("): number");
	assert !out.contains("macro toNum");
}

test "converter: fmt preserves a plain macro's return annotation" {
	const out = fmtSource("export macro plain(n: Node): Node { return n; }");
	assert out.contains("macro plain");
	assert out.contains("): Node");
}

// ===== 9.2 scope law (registry via imports) =====

test "converter: imported converter applies at the boundary" {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: CONV },
		{ entryPath: "src/main.ms", entrySource: `
			import { toNum } from "./lib";
			function main(): void { const x: number = <a/>; }
		` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert !cCode.contains("ERROR:");
}

test "converter: unimported converter does NOT apply" {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: CONV + "export const marker = 1;" },
		{ entryPath: "src/main.ms", entrySource: `
			import { marker } from "./lib";
			function main(): void { const x: number = <a/>; }
		` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert cCode.contains("ERROR:");
	assert cCode.contains("consumed by a macro");
}

test "converter: duplicate source-target pair from two imports is an error" {
	const entries: MapEntry[] = [
		{ entryPath: "src/a.ms", entrySource: CONV },
		{ entryPath: "src/b.ms", entrySource: `
import { Node, NodeKind } from "std/meta";
export converter toNumB(n: Node): number {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 8 };
}
` },
		{ entryPath: "src/main.ms", entrySource: `
			import { toNum } from "./a";
			import { toNumB } from "./b";
			function main(): void { const x: number = <a/>; }
		` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert cCode.contains("ERROR:");
	assert cCode.contains("converter");
}

test "converter: local decl shadows imported converter for the same pair" {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: CONV },
		{ entryPath: "src/main.ms", entrySource: `
			import { Node, NodeKind } from "std/meta";
			import { toNum } from "./lib";
			converter toLocal(n: Node): number {
				return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 8 };
			}
			function main(): void { const x: number = <a/>; }
		` },
	];
	const cCode = compileProjectToCWithStd(entries, "src/main.ms");
	assert !cCode.contains("ERROR:");
	assert cCode.contains("8");
}

// ===== 9.4 diagnostics =====

test "converter: absent converter at a typed boundary — error carries import hint" {
	const c = compileToC("function main(): void { const x: number = <a/>; }");
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("consumed by a macro");
		assert c.error.contains("converter");
	}
}

test "converter: overloaded call needing conversion demands an explicit call" {
	const c = compileToCWithStd(CONV + `
function pick(x: number): number { return x; }
function pick(s: string): number { return 0; }
function main(): void { const y = pick(<a/>); }
`);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("explicit"); }
}
