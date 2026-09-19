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
