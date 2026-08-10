// bug103 — a macro invoked at an EXPRESSION position cannot emit statements
//
// Symptom:    `checkExprPass` expands an eager macro by overwriting the node in
//             place (`node.kind = expanded.kind; node.data = expanded.data`), so
//             the macro holds no statement context and can only produce a single
//             expression. A per-site singleton — memo cache, compiled pattern,
//             render template — must therefore be rebuilt at every evaluation of
//             the call site, which is what makes direct emission lose to the
//             tree path it was meant to beat.
// Today:      a macro returning `SpliceMany` at an expression position reaches
//             codegen untouched (`src/checker/` contains ZERO references to
//             SpliceMany) and dies as `internal: unresolved type (kind=47)`,
//             i.e. an internal error rather than a diagnostic.
// Reference:  Nim builds `nkStmtListExpr` in place — `newTreeIT(nkStmtListExpr,
//             …, hoistedParams, result)` (semexprs.nim:3481): hoisted statements
//             followed by the value as the LAST child. MetaScript rejects the
//             NODE and keeps the substance (docs/NIM-REF.md row 49, FINAL):
//             materialisation is hoist-to-preceding-statement, as already done
//             by `callHoist` / `resultDesugar` / `matchLower`. SpliceMany is the
//             transport only — it is consumed during macro expansion and never
//             reaches transform, analyzer or codegen, so this adds no
//             expression-with-statements node to the AST.
// Contract:   at an expression position the LAST element of SpliceMany is the
//             value substituted at the call site; the preceding elements are
//             hoisted as statements ahead of the enclosing statement. Storage is
//             already handled by `static` (bug102), so the insertion point only
//             decides WHEN the run-once guard executes, never where the slot
//             lives.
//
// Positions are deliberately NOT symmetric, and both halves are pinned below:
// an EMPTY SpliceMany at a statement position splices nothing and stays legal
// (src/test/c/multidecl.ms), while at an expression position it has no last
// element to become the value and must be a loud diagnostic.

// `compileToCWithStd`, not `compileToC`: every source below imports "std/meta"
// to build the macro's return value, and the plain helper keeps stdPath empty
// so those imports do not resolve. src/test/c/multidecl.ms picks the plain one
// and is red today for exactly that reason — a helper mismatch, nothing to do
// with SpliceMany.
import { compileToCWithStd } from "../helpers";

// The slot is string-typed on purpose. bug102's first cut used `int32` and went
// green while the actual defect — module-scope storage still registered for
// scope-exit cleanup — survived untouched, because a non-RC slot needs no
// cleanup. Only an RC payload exercises the path.
test "bug103: a macro at an expression position hoists its SpliceMany prefix" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "cached",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "cached" },
		],
	};
}

let builds: int32 = 0;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function render(): string {
	const v = memo();
	return v;
}

function main(): void { console.log(render() + render()); }
`);
	assert c.ok;
}

// Separate failure mode from the test above: even once the prefix hoists, the
// decl the macro built cannot be marked `static` until the bridge lets that one
// flag survive the trip back from the VM. `flags` deliberately does NOT
// round-trip wholesale — a macro able to set Sem/Transf/LL would forge pipeline
// state — so exactly one member joins the existing BoundSym whitelist.
// `__once` is bug102's run-once guard: its presence proves the hoisted decl
// reached codegen carrying module storage, not merely that it compiled.
test "bug103: a macro can mark the decl it hoists as static storage" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind, NodeFlag } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				flags: NodeFlag.StaticStorage,
				declName: "cached",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "cached" },
		],
	};
}

let builds: int32 = 0;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function render(): string {
	const v = memo();
	return v;
}

function main(): void { console.log(render() + render()); }
`);
	assert c.ok;
	assert c.value.contains("__once");
}

// An empty SpliceMany has no last element, so at an expression position there is
// nothing to substitute. Asserting only `!c.ok` would pass TODAY for the wrong
// reason — the internal codegen error also fails the compile — so the
// diagnostic text is asserted, and the internal-error wording is asserted ABSENT.
test "bug103: an empty SpliceMany at an expression position is a loud error" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro empty(): Node {
	return { kind: NodeKind.SpliceMany, line: 0, column: 0, spliceNodes: [] };
}

function render(): string {
	const v = empty();
	return v;
}

function main(): void { console.log(render()); }
`);
	assert !c.ok;
	assert c.error.contains("no value");
	assert !c.error.contains("internal");
}

// The counterpart pin: at a STATEMENT position an empty SpliceMany splices
// nothing and remains legal. This half passes today and exists so that the
// fail-loud rule above cannot be implemented by rejecting empty SpliceMany
// everywhere, which would break the statement-position contract that
// src/test/c/multidecl.ms already relies on.
test "bug103: an empty SpliceMany at a statement position stays legal" {
	const c = compileToCWithStd(`
import { Node, NodeKind } from "std/meta";

macro empty(): Node {
	return { kind: NodeKind.SpliceMany, line: 0, column: 0, spliceNodes: [] };
}

empty();

function main(): void {}
`);
	assert c.ok;
}

// The reference runs `discardCheck` on every non-last element (semStmtList,
// semstmts.nim:2941), rejecting a prefix element whose value is dropped. That
// rule is deliberately NOT ported: MetaScript follows TypeScript, where `f();`
// discarding a return value is legal, and adopting it would reject ordinary
// statements. What IS worth pinning is the failure mode the rule exists to
// prevent — a prefix element quietly vanishing. An implementation that only
// knows how to hoist declarations would drop this call and lose its side effect
// with no diagnostic, which is the silent-failure shape, not a style question.
test "bug103: a side-effecting prefix element is not dropped" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.ExprStmt,
				line: 0,
				column: 0,
				expr: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "noteBuild" },
					arguments: [],
				},
			},
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "cached",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "cached" },
		],
	};
}

let builds: int32 = 0;
let notes: int32 = 0;
function noteBuild(): void { notes = notes + 1; }
function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function render(): string {
	const v = memo();
	return v;
}

function main(): void { console.log(render() + notes.toString()); }
`);
	assert c.ok;
	assert c.value.contains("noteBuild");
}

// Hoisting to the preceding statement moves the prefix OUT of whatever guarded
// it. At a conditionally-evaluated position that changes semantics: the prefix
// would run even when the branch does not. The reference never faces this —
// `genStmtListExprImpl` (ccgexprs.nim:3219) emits the prefix into the CURRENT
// statement cursor, and `genAndOr` (ccgexprs.nim:1349) has already written the
// branch jump by then, so the prefix lands inside the branch by construction.
// MetaScript materialises during checking, before any conditional lowering, so
// it has no such cursor and must refuse instead of silently changing meaning.
// Refusing is not a second re-sequencing mechanism — it declines a position.
//
// Measured pre-fix behaviour, and it is worse than the unconditional case: this
// source COMPILES clean through the checker (no diagnostic at all), and C
// codegen falls through to a placeholder, emitting
//   (dollarscres_1_ = (/* unsupported expression: kind=SpliceMany */ != ...))
// which only fails because the vanished operand left `!=` without a left side.
// A differently shaped expression could swallow that comment and produce VALID
// but wrong C. So the assertion here is that a diagnostic exists at all; the
// internal-error wording is asserted absent so a late internal error cannot
// satisfy it either.
test "bug103: a macro at a conditionally-evaluated position is refused" {
	const c = compileToCWithStd(`
import { Node, NodeKind, DeclKind } from "std/meta";

macro memo(): Node {
	return {
		kind: NodeKind.SpliceMany,
		line: 0,
		column: 0,
		spliceNodes: [
			{
				kind: NodeKind.VariableDecl,
				line: 0,
				column: 0,
				declName: "cached",
				declType: "string",
				initializer: {
					kind: NodeKind.CallExpr,
					line: 0,
					column: 0,
					callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: "build" },
					arguments: [],
				},
				declKind: DeclKind.Const,
				nameLocation: { line: 0, column: 0 },
			},
			{ kind: NodeKind.Identifier, line: 0, column: 0, name: "cached" },
		],
	};
}

let builds: int32 = 0;
let flag: boolean = true;
function build(): string { builds = builds + 1; return "T" + builds.toString(); }

function check(): boolean {
	return flag && memo() !== "";
}

function main(): void { console.log(check().toString()); }
`);
	assert !c.ok;
	assert c.error.contains("conditionally evaluated");
	assert !c.error.contains("internal");
}
