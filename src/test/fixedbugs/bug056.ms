// bug056 — bindSym: macros emit pre-bound identifiers (Nim semBindSym model)
//
// Gap: macros emit bare Identifier nodes that the checker resolves in the
// USER's scope — every helper a codec macro calls must be imported by name at
// the call site (the 7-name import lists of SERIALIZE.md §11), and a user-local
// name silently hijacks the macro's callee. `bindSym("name")` resolves in the
// macro's DECLARING module scope at bake time (bakeTypeIntrinsics), registers
// the real Symbol (bridge registerBoundSym), and splices an Identifier literal
// carrying its handle. valueToNode rebinds the Symbol + NodeFlag.BoundSym on
// the way out; checkExprPass honors the pre-bound symbol instead of lookup.

import { compileToCWithStd, compileProjectToCWithStd, MapEntry } from "../helpers";

const libSrc = `
import { Node, NodeKind } from "std/meta";

function dbl(n: number): number { return n * 2; }

export macro twice(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("dbl"), arguments: [x] };
}
`;

test "bug056: bound callee needs no import at the call site" {
	const entries: MapEntry[] = [
		{ entryPath: "test/lib.ms", entrySource: libSrc },
		{ entryPath: "test/main.ms", entrySource: `
import { twice } from "./lib";

function main(): void {
	console.log(twice(21));
}
` },
	];
	const out = compileProjectToCWithStd(entries, "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0;
	assert out.indexOf("dbl", 0) >= 0;
}

test "bug056: user-scope name cannot hijack the bound symbol" {
	const entries: MapEntry[] = [
		{ entryPath: "test/lib.ms", entrySource: libSrc },
		{ entryPath: "test/main.ms", entrySource: `
import { twice } from "./lib";

function dbl(s: string): string { return s; }

function main(): void {
	console.log(twice(21));
}
` },
	];
	const out = compileProjectToCWithStd(entries, "test/main.ms");
	assert out.indexOf("ERROR", 0) < 0;
}

test "bug056: function-local shadow does not capture the bound callee" {
	const src = `
import { Node, NodeKind } from "std/meta";

function dbl(n: number): number { return n * 2; }

export macro twice(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("dbl"), arguments: [x] };
}

function main(): void {
	const dbl: number = 7;
	console.log(twice(21) + dbl);
}
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "bug056: unresolvable bindSym reports a clear error" {
	const src = `
import { Node, NodeKind } from "std/meta";

export macro broken(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("noSuchHelper"), arguments: [x] };
}

function main(): void {
	console.log(broken(1));
}
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	assert c.error.indexOf("bindSym cannot resolve", 0) >= 0;
}

// ===== bindSym V2: bound MACROS + symHandle through nested expansion =====

const libMacroSrc = `
import { Node, NodeKind } from "std/meta";

function dbl(n: number): number { return n * 2; }

export macro inner(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("dbl"), arguments: [x] };
}

export macro outer(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("inner"), arguments: [x] };
}
`;

test "bug056: bound MACRO expands without being imported at the call site" {
	const entries: MapEntry[] = [
		{ entryPath: "test/libm.ms", entrySource: libMacroSrc },
		{ entryPath: "test/mainm.ms", entrySource: `
import { outer } from "./libm";

function main(): void {
	console.log(outer(21));
}
` },
	];
	const out = compileProjectToCWithStd(entries, "test/mainm.ms");
	assert out.indexOf("ERROR", 0) < 0;
	assert out.indexOf("dbl", 0) >= 0;
}

test "bug056: user-scope name cannot hijack a bound macro" {
	const entries: MapEntry[] = [
		{ entryPath: "test/libm.ms", entrySource: libMacroSrc },
		{ entryPath: "test/mainm.ms", entrySource: `
import { outer } from "./libm";

function inner(s: string): string { return s; }

function main(): void {
	console.log(outer(21));
}
` },
	];
	const out = compileProjectToCWithStd(entries, "test/mainm.ms");
	assert out.indexOf("ERROR", 0) < 0;
}

const libPassSrc = `
import { Node, NodeKind } from "std/meta";

function dbl(n: number): number { return n * 2; }

export macro callIt(f: Node): Node {
	return { kind: NodeKind.CallExpr, line: f.line, column: f.column,
		callee: f,
		arguments: [{ kind: NodeKind.NumberLiteral, line: f.line, column: f.column, value: 21 }] };
}

export macro outer2(x: Node): Node {
	return { kind: NodeKind.CallExpr, line: x.line, column: x.column,
		callee: bindSym("callIt"), arguments: [bindSym("dbl")] };
}
`;

test "bug056: bound identifier survives passing through a second macro" {
	const entries: MapEntry[] = [
		{ entryPath: "test/libp.ms", entrySource: libPassSrc },
		{ entryPath: "test/mainp.ms", entrySource: `
import { outer2 } from "./libp";

function main(): void {
	console.log(outer2(0));
}
` },
	];
	const out = compileProjectToCWithStd(entries, "test/mainp.ms");
	assert out.indexOf("ERROR", 0) < 0;
	assert out.indexOf("dbl", 0) >= 0;
}
