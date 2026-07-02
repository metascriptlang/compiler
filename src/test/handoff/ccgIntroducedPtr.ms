// Route 2: ccgIntroducedPtr — type→pointer decision
//
// Verifies the codegen decision of whether to introduce pointer params
// based on struct size, interface flag, and Ref wrapping.

import { createStruct, createRef, createPtr, numberType, stringType, createMaybeType } from "../../checker/types";
import { ccgIntroducedPtr, isPointerType } from "../../codegen/c/types";
import { fullPipeline, findFnDecl } from "./helpers";
import { Node, NodeKind, ProgramData, ExportDeclData, FunctionDeclData, CallExprData, BlockStmtData, IfStmtData, ReturnStmtData, ExprStmtData, TypeKind } from "../../ast/node";

test "ccgIntroducedPtr: small struct = false" {
	const t = createStruct("Small", ["x", "y"], [numberType(), numberType()], true);
	assert !ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: large struct = true" {
	const t = createStruct("Big", ["a", "b", "c", "d"], [numberType(), numberType(), numberType(), numberType()], true);
	assert ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: struct with string fields = true" {
	const t = createStruct("WithStr", ["x", "name", "desc"], [numberType(), stringType(), stringType()], true);
	assert ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: Ref type = false" {
	const inner = createStruct("FooRef", ["x"], [numberType()], true);
	const ref = createRef(inner);
	assert !ccgIntroducedPtr(ref);
}

test "ccgIntroducedPtr: non-interface struct = false" {
	const t = createStruct("Raw", ["a", "b", "c", "d"], [numberType(), numberType(), numberType(), numberType()], false);
	assert !ccgIntroducedPtr(t);
}

test "ccgIntroducedPtr: class type (Ref<Struct>) = false" {
	const inner = createStruct("DocR", ["kind", "name", "desc", "extra"], [numberType(), stringType(), stringType(), stringType()], true);
	const classType = createRef(inner);
	assert !ccgIntroducedPtr(classType);
}

test "ccgIntroducedPtr: unwrapped class inner struct = true" {
	const inner = createStruct("DocRI", ["kind", "name", "desc", "extra"], [numberType(), stringType(), stringType(), stringType()], true);
	assert ccgIntroducedPtr(inner);
}

test "ccgIntroducedPtr: Maybe wrapper large enough" {
	const inner = createStruct("BigTokM", ["kind", "value", "extra"], [numberType(), stringType(), stringType()], true);
	const maybe = createMaybeType(inner);
	assert ccgIntroducedPtr(maybe);
}

test "ccgIntroducedPtr: collapsed Maybe<Ref<T>> = false" {
	const inner = createStruct("FooMC", ["x"], [numberType()], true);
	const ref = createRef(inner);
	const maybe = createMaybeType(ref);
	assert !ccgIntroducedPtr(maybe);
}

// ===== E2E: Verify call-site C output =====

import { compileToC } from "../helpers";

// When both caller and callee have ccgIntroducedPtr params (BigStruct*),
// the call site must pass the pointer directly — not dereference *(param).
test "E2E ccgPtr: direct call" {
	const src = "interface BigS { a: number; b: number; c: number; d: number; e: string }\n" +
		"export function process(item: BigS): number { return item.a; }\n" +
		"export function caller(item: BigS): number { return process(item); }";
	const c = compileToC(src);
	console.log("=== DIRECT ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: match expression" {
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"export function handleA(d: BigS): number { return d.value; }\n" +
		"export function handleB(d: BigS): number { return d.kind; }\n" +
		"export function dispatch(d: BigS): number {\n" +
		"  return match (d.kind) {\n" +
		"    1 => handleA(d),\n" +
		"    2 => handleB(d),\n" +
		"    _ => 0,\n" +
		"  };\n" +
		"}";
	const c = compileToC(src);
	console.log("=== MATCH ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: static fns in match (real pattern)" {
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"function handleA(d: BigS): BigS { return d; }\n" +
		"function handleB(d: BigS): BigS { return d; }\n" +
		"export function dispatch(d: BigS): BigS {\n" +
		"  return match (d.kind) {\n" +
		"    1 => handleA(d),\n" +
		"    2 => handleB(d),\n" +
		"    _ => d,\n" +
		"  };\n" +
		"}";
	const c = compileToC(src);
	console.log("=== STATIC MATCH ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: walkNode callback pattern" {
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type Walker = (node: BigS) => BigS;\n" +
		"function walkNode(node: BigS, walker: Walker): BigS { return walker(node); }\n" +
		"function foldBinary(node: BigS): BigS { return node; }\n" +
		"function foldNode(node: BigS): BigS {\n" +
		"  if (node.kind === 1) { return foldBinary(node); }\n" +
		"  return node;\n" +
		"}\n" +
		"export function main(node: BigS): BigS { return walkNode(node, foldNode); }";
	const c = compileToC(src);
	console.log("=== WALKNODE ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: class type (Ref) call" {
	const src = "class Foo { kind: number; value: number; name: string; extra: string }\n" +
		"export function process(item: Foo): Foo { return item; }\n" +
		"export function caller(item: Foo): Foo { return process(item); }";
	const c = compileToC(src);
	console.log("=== CLASS ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: class if/else — static callee" {
	const src = "class Item { kind: number; value: number; name: string }\n" +
		"function handleA(item: Item): Item { return item; }\n" +
		"export function dispatch(item: Item): Item {\n" +
		"  if (item.kind === 1) { return handleA(item); }\n" +
		"  return item;\n" +
		"}";
	const c = compileToC(src);
	console.log("=== STATIC CALLEE ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: class if/else — exported callee" {
	const src = "class Item { kind: number; value: number; name: string }\n" +
		"export function handleA(item: Item): Item { return item; }\n" +
		"export function dispatch(item: Item): Item {\n" +
		"  if (item.kind === 1) { return handleA(item); }\n" +
		"  return item;\n" +
		"}";
	const c = compileToC(src);
	console.log("=== EXPORTED CALLEE ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "AST: resolvedSym on call — static vs exported callee" {
	// Use compileToC but also inspect the AST via fullPipeline
	// The fullPipeline includes transforms but NOT DRC or codegen
	const src = "class Item { kind: number; value: number; name: string }\n" +
		"export function handleA(item: Item): Item { return item; }\n" +
		"export function handleB(item: Item): Item { return item; }\n" +
		"export function dispatch(item: Item): Item {\n" +
		"  if (item.kind === 1) { return handleA(item); }\n" +
		"  return handleB(item);\n" +
		"}";
	const ast = fullPipeline(src);
	if (ast === null) { console.log("AST is null"); return; }
	console.log("AST kind=" + ast.kind + " Program=" + NodeKind.Program);
	const pd = ast.data as ProgramData;
	console.log("stmts=" + pd.programStmts.length);
	let i = 0;
	while (i < pd.programStmts.length) {
		const s = pd.programStmts[i];
		let inner = s;
		// Unwrap ExportDecl
		if (inner.kind === NodeKind.ExportDecl) {
			const ed = inner.data as ExportDeclData;
			inner = ed.exportedDecl;
		}
		if (inner.kind === NodeKind.FunctionDecl) {
			const fd = inner.data as FunctionDeclData;
			console.log("  fn: " + fd.fnName);
			if (fd.fnName === "dispatch") {
				walkCalls(fd.fnBody);
			}
		}
		i = i + 1;
	}
}

function walkCalls(node: Node): void {
	if (node === null) return;
	console.log("  walk kind=" + node.kind);
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const sym = node.resolvedSym;
		const name = sym !== null ? sym.name : "null";
		let info = "CALL " + name + ": resolvedSym=" + (sym !== null ? "Y" : "N");
		if (sym !== null && sym.symbolType !== null) {
			const st = sym.symbolType;
			info = info + " symTypeKind=" + st.kind;
			if (st.typeChildren !== null && st.typeChildren.length > 0) {
				info = info + " param0Kind=" + st.typeChildren[0].kind + " param0IsPtr=" + isPointerType(st.typeChildren[0]);
			}
		}
		if (cd.callee.nodeType !== null) {
			const cnt = cd.callee.nodeType;
			info = info + " calleeNTKind=" + cnt.kind;
			if (cnt.typeChildren !== null && cnt.typeChildren.length > 0) {
				info = info + " cParam0Kind=" + cnt.typeChildren[0].kind + " cParam0IsPtr=" + isPointerType(cnt.typeChildren[0]);
			}
		}
		if (cd.arguments.length > 0) {
			const a = cd.arguments[0];
			info = info + " arg0Kind=" + a.kind + " arg0NTKind=" + (a.nodeType !== null ? a.nodeType.kind : -1);
		}
		console.log(info);
		return;
	}
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		let j = 0;
		while (j < bd.statements.length) { walkCalls(bd.statements[j]); j = j + 1; }
	} else if (node.kind === NodeKind.IfStmt) {
		const id = node.data as IfStmtData;
		walkCalls(id.consequent);
		if (id.alternate !== null) walkCalls(id.alternate);
	} else if (node.kind === NodeKind.ReturnStmt) {
		const rd = node.data as ReturnStmtData;
		walkCalls(rd.argument);
	} else if (node.kind === NodeKind.ExprStmt) {
		const ed = node.data as ExprStmtData;
		walkCalls(ed.expr);
	}
}

test "E2E ccgPtr: class type in match arms" {
	const src = "class Item { kind: number; value: number; name: string }\n" +
		"function handleA(item: Item): Item { return item; }\n" +
		"function handleB(item: Item): Item { return item; }\n" +
		"export function dispatch(item: Item): Item {\n" +
		"  return match (item.kind) {\n" +
		"    1 => handleA(item),\n" +
		"    2 => handleB(item),\n" +
		"    _ => item,\n" +
		"  };\n" +
		"}";
	const c = compileToC(src);
	console.log("=== CLASS MATCH ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: closure call" {
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type Handler = (d: BigS) => number;\n" +
		"export function run(h: Handler, d: BigS): number { return h(d); }";
	const c = compileToC(src);
	console.log("=== CLOSURE ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E: empty string[] arg type" {
	const src = "function takesNames(names: string[]): number { return names.length; }\n" +
		"export function main(): number { return takesNames([]); }";
	const c = compileToC(src);
	console.log("=== EMPTY STR ARR ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E: nested call with empty string[] arg" {
	// Reproduce the real pattern: createStruct(name, [], [], true) inside makeSymbol inside defineOrError
	const src = "interface Pair { names: string[]; values: number[] }\n" +
		"function makePair(names: string[], values: number[]): Pair { return { names, values }; }\n" +
		"function wrap(p: Pair): Pair { return p; }\n" +
		"export function main(): Pair { return wrap(makePair([], [])); }";
	const c = compileToC(src);
	console.log("=== NESTED EMPTY ARR ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: try + ccgIntroducedPtr param" {
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type BigResult = Result<BigS, string>;\n" +
		"function parse(d: BigS): BigResult { return Result.ok(d); }\n" +
		"export function caller(d: BigS): BigResult {\n" +
		"  const inner = try parse(d);\n" +
		"  return Result.ok(inner);\n" +
		"}";
	const c = compileToC(src);
	console.log("=== TRY CCGPTR ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: direct call same function (no try)" {
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type BigResult = Result<BigS, string>;\n" +
		"function parse(d: BigS): BigResult { return Result.ok(d); }\n" +
		"export function caller(d: BigS): BigResult {\n" +
		"  return parse(d);\n" +
		"}";
	const c = compileToC(src);
	console.log("=== DIRECT NO TRY ===");
	if (c.ok) { console.log(c.value); } else { console.log("ERR: " + c.error); }
}

test "E2E ccgPtr: try desugar - arg nodeType check" {
	// Reproduce the real pattern: try + cross-module call to function with big struct param
	// After try desugar, the call's arg should still have nodeType
	const src = "interface BigS { kind: number; value: number; name: string; extra: string }\n" +
		"type BigResult = Result<BigS, string>;\n" +
		"function parse(d: BigS): BigResult { return Result.ok(d); }\n" +
		"export function caller(d: BigS): BigResult {\n" +
		"  const inner = try parse(d);\n" +
		"  return Result.ok(inner);\n" +
		"}";
	const ast = fullPipeline(src);
	if (ast === null) { console.log("AST null"); return; }
	const pd = ast.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		let s = pd.programStmts[i];
		if (s.kind === NodeKind.ExportDecl) {
			s = (s.data as ExportDeclData).exportedDecl;
		}
		if (s.kind === NodeKind.FunctionDecl) {
			const fd = s.data as FunctionDeclData;
			if (fd.fnName === "caller") {
				console.log("=== CALLER AST ===");
				walkCalls(fd.fnBody);
			}
		}
		i = i + 1;
	}
}

// ===== Empty array param typing (reference: semArrayConstr expectedType) =====

test "E2E: empty [] arg typed as string[] param" {
	const src = "function foo(names: string[]): number { return names.length; }\nconst x = foo([]);";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("msStringArray");
}

test "E2E: empty [] arg typed as Type[] param" {
	const src = "interface Foo { x: number; }\nfunction bar(items: Foo[]): number { return items.length; }\nconst y = bar([]);";
	const result = compileToC(src);
	assert result.ok;
	// Arrays are reference types (Ref<Array>) after the T[]→Ref<Array> flip, so an
	// empty [] arg lowers to an empty ref-array literal.
	assert result.value.contains("(msRefArray){0}");
}

import { compileProjectToC, MapEntry } from "../helpers";

test "MULTI: empty [] arg typed as string[] cross-module" {
	const libSrc = "export function makeStruct(name: string, fields: string[]): number { return fields.length; }";
	const mainSrc = "import { makeStruct } from \"./lib\";\nconst x = makeStruct(\"Foo\", []);";
	const entries: MapEntry[] = [
		{ entryPath: "test/main.ms", entrySource: mainSrc },
		{ entryPath: "test/lib.ms", entrySource: libSrc },
	];
	const result = compileProjectToC(entries, "test/main.ms");
	// This helper verifies cross-module resolution only: makeStruct is emitted iff
	// the "./lib" import actually loaded (it silently didn't before map-key
	// canonicalization). The empty-[] element-type (msStringArray vs msRefArray)
	// needs refineTypes/lowerNativeAccess, which this string-grep pipeline skips —
	// that property is verified against msc-const directly, not here.
	assert !result.contains("ERROR:");
	assert result.contains("makeStruct");
	assert !result.contains("msAnon_");
}
