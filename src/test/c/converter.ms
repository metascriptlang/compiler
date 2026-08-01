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

test "converter: runtime-typed source param is rejected" {
	const c = compileToC(`
import { Node, NodeKind } from "std/meta";
export converter bad(x: number): number {
	return { kind: NodeKind.NumberLiteral, line: 1, column: 1, value: 7 };
}
function main(): void { }
`);
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("compile-time"); }
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
