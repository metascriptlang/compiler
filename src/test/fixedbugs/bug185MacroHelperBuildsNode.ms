// bug185 — a macro that builds nodes in a module-scope helper shipped null children
//
// Symptom:    the compiler died with SIGSEGV, no diagnostic and no location,
//             when a macro's returned tree took a child from a helper instead
//             of building it inline.
// Root:       `createNodeAt` is a syntactic rewrite (`tryRewriteCreateNodeAt`)
//             driven by `applyPreprocessRewrites`, and `preprocessMacroBody`
//             only ever ran on the macro body. A module-scope helper reached
//             the VM unrewritten, evaluated to Nil, and `readNode` turned that
//             Nil into a null Node the checker then dereferenced.
// Fix:        `ensureCompiledIntoEngine` preprocesses the helper CLONE it
//             compiles into the comptime engine, so node construction works
//             anywhere comptime code reaches — the way Nim's mNNewNimNode is
//             callable from any proc the VM executes. The rewrite also peels
//             the hidden conversions an already-checked helper body carries.
// Found by:   Neon, generating applyCssProp from one field table.
import { compileToCWithStd } from "../helpers";

test "bug185: a helper building a node expands like the inline call" {
	const c = compileToCWithStd(`
import { Node, NodeKind, SourceLocation, createNodeAt } from "std/meta";

function mk42(loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, loc);
}

macro sum(a: Node): Node {
	const loc: SourceLocation = { line: a.line, column: a.column };
	return { kind: NodeKind.BinaryExpr, line: a.line, column: a.column, operator: "+",
		left: mk42(loc), right: mk42(loc) };
}

function main(): void {
	const x: number = sum(1);
	console.log(x.toString());
}
main();
`);
	assert c.ok, "the helper-built tree must reach codegen: " + c.error;
	assert c.value.contains("42 + 42") || c.value.contains("84"), "the expansion must carry both operands: " + c.value;
}

test "bug185: a helper's node bound to a macro-body const also expands" {
	const c = compileToCWithStd(`
import { Node, NodeKind, SourceLocation, createNodeAt } from "std/meta";

function mk42(loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, loc);
}

macro sum(a: Node): Node {
	const loc: SourceLocation = { line: a.line, column: a.column };
	const inner = mk42(loc);
	return { kind: NodeKind.BinaryExpr, line: a.line, column: a.column, operator: "+", left: inner, right: inner };
}

function main(): void {
	const x: number = sum(1);
	console.log(x.toString());
}
main();
`);
	assert c.ok, "a helper result held in a const must survive: " + c.error;
	assert c.value.contains("42 + 42") || c.value.contains("84"), "the expansion must carry both operands: " + c.value;
}

test "bug185: the rewrite reaches a helper called from another helper" {
	const c = compileToCWithStd(`
import { Node, NodeKind, SourceLocation, createNodeAt } from "std/meta";

function leaf(loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, loc);
}

function branch(loc: SourceLocation): Node {
	return leaf(loc);
}

macro sum(a: Node): Node {
	const loc: SourceLocation = { line: a.line, column: a.column };
	return { kind: NodeKind.BinaryExpr, line: a.line, column: a.column, operator: "+",
		left: branch(loc), right: branch(loc) };
}

function main(): void {
	const x: number = sum(1);
	console.log(x.toString());
}
main();
`);
	assert c.ok, "a transitively reached helper must be rewritten too: " + c.error;
	assert c.value.contains("42 + 42") || c.value.contains("84"), "the expansion must carry both operands: " + c.value;
}
