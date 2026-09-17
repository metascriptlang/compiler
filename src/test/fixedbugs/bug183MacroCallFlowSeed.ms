// bug183 — a guard emitted by a call-form macro does not narrow
//
// Symptom:    a macro that emits `const t = <arg>; if (t !== null) { use(t); }`
//             fails the check of `use(t)` with `got Maybe_…, expected string`,
//             while the same statements written as source narrow.
// Root:       every macro invocation is a bare call, so the binder sees a
//             CallExpr. `bindCallExpr` stamped no program point; the checker
//             later rewrites the node IN PLACE to MacroInvocation and hands
//             `node.flowNode` (still null) to `bindExpandedSubtree`, which
//             returns early — the expansion is never flow-bound. Only a node
//             that was already a MacroInvocation at bind time (mono's
//             `bindFunctionFlow` over a cloned body) carried a seed.
// Fix:        `bindCallExpr` stamps `node.flowNode` after its callee and
//             arguments, the same point the MacroInvocation arm stamps; and
//             `bindStatement` walks a SpliceMany expansion element by element
//             (it fell to the expression fallback, which ignored it).
//             Third hole, same repro: the macro omits `alternate`. The parser
//             gives an else-less `if` an EMPTY block and every pass walks it
//             on that invariant; the bridge rebuilt the node with a NULL
//             `alternate`, so asyncDesugar's walkAsync dereferenced null and
//             the compiler segfaulted with no diagnostic. `valueToNode` now
//             restores the parser's empty block.
// Found by:   Neon arc "one NeonNode" Lát 0.11 (nullable on*/ref/style emit a
//             presence guard from the `direct` macro).
import { compileToCWithStd } from "../helpers";

test "bug183: a null guard emitted by a call-form macro narrows its temp" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind } from "std/meta";

macro whenPresent(value: Node, fn: Node): Node {
	const ln = value.line;
	const col = value.column;
	return {
		kind: NodeKind.ArrowFunction, line: ln, column: col,
		arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
		arrowBody: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
			{ kind: NodeKind.VariableDecl, line: ln, column: col, declName: "_o0", declType: "", declKind: DeclKind.Const, initializer: value },
			{ kind: NodeKind.IfStmt, line: ln, column: col,
				condition: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "!==", left: { kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }, right: { kind: NodeKind.NullLiteral, line: ln, column: col } },
				consequent: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
					{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: { kind: NodeKind.CallExpr, line: ln, column: col, callee: fn, arguments: [{ kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }] } },
				] },
			},
		] },
	};
}

function take(s: string): void { console.log("got " + s); }

function run(s: string | null): void {
	const go = whenPresent(s, take);
	go();
}

run("abc");
run(null);
`);
	assert c.ok, "the emitted guard must narrow: " + (c.ok ? "" : c.error);
}

test "bug183: the value of a SpliceMany expansion is flow-bound too" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind } from "std/meta";

macro whenPresent(value: Node, fn: Node): Node {
	const ln = value.line;
	const col = value.column;
	return { kind: NodeKind.SpliceMany, line: ln, column: col, spliceNodes: [
		{ kind: NodeKind.VariableDecl, line: ln, column: col, declName: "_hoisted", declType: "", declKind: DeclKind.Const, initializer: { kind: NodeKind.StringLiteral, line: ln, column: col, value: "x" } },
		{
		kind: NodeKind.ArrowFunction, line: ln, column: col,
		arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
		arrowBody: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
			{ kind: NodeKind.VariableDecl, line: ln, column: col, declName: "_o0", declType: "", declKind: DeclKind.Const, initializer: value },
			{ kind: NodeKind.IfStmt, line: ln, column: col,
				condition: { kind: NodeKind.BinaryExpr, line: ln, column: col, operator: "!==", left: { kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }, right: { kind: NodeKind.NullLiteral, line: ln, column: col } },
				consequent: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
					{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: { kind: NodeKind.CallExpr, line: ln, column: col, callee: fn, arguments: [{ kind: NodeKind.Identifier, line: ln, column: col, name: "_o0" }] } },
				] },
			},
		] },
	} ] };
}

function take(s: string): void { console.log("got " + s); }

function run(s: string | null): void {
	const go = whenPresent(s, take);
	go();
}

run("abc");
run(null);
`);
	assert c.ok, "the emitted guard must narrow: " + (c.ok ? "" : c.error);
}

test "bug183: an else-less IfStmt from a macro gets the parser's empty alternate" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro ifTrue(fn: Node): Node {
	const ln = fn.line;
	const col = fn.column;
	return {
		kind: NodeKind.ArrowFunction, line: ln, column: col,
		arrowParams: [], arrowParamTypes: [], arrowFlags: "", arrowReturnType: "",
		arrowBody: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
			{ kind: NodeKind.IfStmt, line: ln, column: col,
				condition: { kind: NodeKind.BooleanLiteral, line: ln, column: col, boolValue: true },
				consequent: { kind: NodeKind.BlockStmt, line: ln, column: col, statements: [
					{ kind: NodeKind.ExprStmt, line: ln, column: col, expr: { kind: NodeKind.CallExpr, line: ln, column: col, callee: fn, arguments: [] } },
				] },
			},
		] },
	};
}

function hi(): void { console.log("hi"); }
const go = ifTrue(hi);
go();
`);
	assert c.ok, "an absent alternate must not reach the passes as null: " + (c.ok ? "" : c.error);
}
