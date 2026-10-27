// Parser contract: every node the parser finishes carries a source range. No tier index owns a
// parser-only invariant, so this module stands alone: `msc test src/test/parser/nodeRanges.ms`.
// Columns are 1-based bytes, the unit of Token.column.

import { parseSource } from "../../parser/statements/validation";
import { registerCoreParsers } from "../../parser/statements/core";
import { readFile } from "std/fs";
import { Node, NodeKind, SourceLocation, StringLiteralData, BlockStmtData, ProgramData, ExprStmtData } from "../../ast/node";
import { nodeKindName } from "../../ast/fieldspec";
import { forEachChild } from "../../ast/visitor";

function key(line: int32, column: int32): int64 {
	return (line as int64) * 1048576 + (column as int64);
}

function endKey(loc: SourceLocation): int64 {
	return key(loc.endLine, loc.endColumn);
}

function realChildren(node: Node, out: Node[]): void {
	forEachChild(node, (child: Node): void => {
		if (child.location.line == 0) realChildren(child, out);
		else out.push(child);
	});
}

// Nodes the parser builds from a parent's anchor token with no source text of their own keep no end:
// the absent else or catch or finally block and the empty body of an extern or overload signature, the "" seed of a template concatenation and the implicit
// `true` of a bare JSX attribute.
function isSynthetic(node: Node, parent: Node | null): boolean {
	if (parent == null || node.location.endLine != 0) return false;
	if (node.location.line != parent.location.line || node.location.column != parent.location.column) return false;
	return match (node.kind) {
		NodeKind.BlockStmt => (node.data as BlockStmtData).statements.length == 0 && (parent.kind == NodeKind.IfStmt || parent.kind == NodeKind.TryCatchStmt || parent.kind == NodeKind.FunctionDecl || parent.kind == NodeKind.MethodDecl),
		NodeKind.StringLiteral => (node.data as StringLiteralData).value == "" && parent.kind == NodeKind.BinaryExpr,
		NodeKind.BooleanLiteral => parent.kind == NodeKind.JSXAttribute,
		_ => false,
	};
}

// Returns where the node's span starts: its own anchor, or an earlier child when the anchor is an operator.
function visit(node: Node, parent: Node | null, found: string[]): int64 {
	const loc = node.location;
	const name = `${nodeKindName(node.kind)}@${loc.line}:${loc.column}`;
	const children: Node[] = [];
	realChildren(node, children);
	const starts: int64[] = [];
	let spanStart = key(loc.line, loc.column);
	for (const child of children) {
		const childStart = visit(child, node, found);
		starts.push(childStart);
		if (childStart < spanStart) spanStart = childStart;
	}
	if (loc.endLine == 0) {
		if (!isSynthetic(node, parent)) found.push(`${name} has no end`);
	}
	else if (endKey(loc) < spanStart) found.push(`${name} ends before it starts`);
	for (let i = 0; i < children.length; i += 1) {
		const child = children[i].location;
		const childName = `${nodeKindName(children[i].kind)}@${child.line}:${child.column}`;
		if (child.endLine == 0) continue;
		if (loc.endLine != 0 && endKey(child) > endKey(loc)) found.push(`${name} ends before its child ${childName}`);
		for (let j = 0; j < children.length; j += 1) {
			if (starts[i] < starts[j] && endKey(child) > starts[j]) {
				found.push(`${name} children overlap: ${childName} runs into ${nodeKindName(children[j].kind)}@${children[j].location.line}:${children[j].location.column}`);
			}
		}
	}
	return spanStart;
}

export function rangeViolations(source: string): string[] {
	registerCoreParsers();
	const parsed = parseSource(source);
	const found: string[] = [];
	if (!parsed.ok) {
		found.push(`parse error: ${parsed.error}`);
		return found;
	}
	visit(parsed.value, null, found);
	return found;
}

function expectClean(source: string): string {
	const found = rangeViolations(source);
	return found.length == 0 ? "" : `${found.join("; ")} in: ${source}`;
}

function programStmt(source: string, index: int32): Node {
	registerCoreParsers();
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error(parsed.error);
	return (parsed.value.data as ProgramData).programStmts[index];
}

test "calls, members, binary chains and conditionals are ranged" {
	const problem = expectClean("const a = f(1, g(2)) + x.y.z * [1, 2][0] - (b ? c : d);");
	assert problem == "";
}

test "object and array literals, arrows and patterns are ranged" {
	assert expectClean("const o = { a: 1, b, [k]: v, ...rest, c: () => 1, d: async (x: int32) => { return x; } };") == "";
	assert expectClean("const [p, q = 1, ...r] = xs; const { u, v: w = 2, ...t } = ys;") == "";
}

test "functions, classes, structs, enums, interfaces and aliases are ranged" {
	assert expectClean("function f<T>(a: T, b: int32 = 2): Map<string, T[]> | null { return a as T; }") == "";
	assert expectClean("class A<T> extends B { private x: int32 = 1; constructor(a: int32) { this.x = a; } get z(): int32 { return 1; } m<U>(u: U): void { u!; } }") == "";
	assert expectClean("struct P { x: int32; y: int32 } enum E { A, B = 2 } interface I { f: int32 } type U = { a: string } | string[]; export const k = 1, l = 2;") == "";
}

test "match, JSX and control flow are ranged" {
	assert expectClean("const m = match (x) { 1 | 2 => \"a\", E.A when ok => { return 1; }, _ => f(x) };") == "";
	assert expectClean("const j = <div class=\"a\" {...p} onClick={() => 1}>text {x} <b/></div>; const fr = <><i>1</i></>;") == "";
	assert expectClean("if (a) b(); else if (c) { d(); } else e(); for (let i = 0; i < 3; i++) {} for (const v of xs) {} while (x) { break; } do { y(); } while (z);") == "";
	assert expectClean("switch (x) { case 1: case 2: f(); break; default: g(); } try { a(); } catch (e) { b(); } finally { c(); } defer f(); assert x == 1, \"msg\";") == "";
}

test "a multi-line template and a string with escapes end where they close" {
	assert expectClean("const s = `a ${b} c ${d + 1}\ntail\nmore`; const t = `plain`; const u = \"esc\\n\\t\";") == "";
	const stmt = programStmt("const u = \"a\\tb\"\n;", 0);
	assert stmt.location.endLine == 2 && stmt.location.endColumn == 2;
}

test "imports, exports and decorators are ranged" {
	assert expectClean("import { a, b as c } from \"m\"; export * from \"n\"; @inline function g(): void {}") == "";
}

test "fmt case inputs are ranged" {
	const names = ["binaryMember", "adjacentDecorated", "binaryPrecedence", "conditionalMember", "arrowCallee", "assertionOperands", "aliasComments", "actorStaticBlock"];
	for (const name of names) {
		const file = readFile(`src/test/fmt/cases/${name}.ms`);
		assert file.ok;
		if (file.ok) {
			const problem = expectClean(file.value);
			assert problem == "";
		}
	}
}

test "an end column counts bytes after non-ASCII text" {
	const source = "const s = \"é😀\"; f(s);";
	const decl = programStmt(source, 0);
	const call = (programStmt(source, 1).data as ExprStmtData).expr;
	assert decl.location.endColumn == 20;
	assert programStmt(source, 1).location.endColumn == 26;
	assert call.location.endColumn == 25;
	assert expectClean(source) == "";
}
